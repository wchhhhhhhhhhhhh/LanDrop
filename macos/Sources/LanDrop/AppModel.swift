import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    // 本机
    @Published private(set) var isRunning = false
    @Published private(set) var port = 0
    @Published private(set) var statusText = "正在启动…"
    @Published var deviceName: String
    @Published var pinEnabled: Bool
    @Published var pin: String
    @Published var inboxPath: String

    // 数据
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var files: [FileItem] = []
    @Published private(set) var transfers: [Transfer] = []

    // 界面
    @Published var selectedPeerID: String?
    @Published var showSettings = false
    @Published var showTextComposer = false
    @Published var browsePeer: Peer?
    @Published var manualAdd = false
    @Published var toast: String?
    @Published var pendingPinPeer: Peer?

    private lazy var store = FileStore(inbox: Config.shared.inbox)
    private lazy var server = HTTPServer(store: store, config: Config.shared)
    private lazy var discovery = Discovery(config: Config.shared, serverPort: { [weak self] in
        self?.server.port ?? 47823
    })

    private var timers: [Timer] = []
    private var peerPins: [String: String] = [:]
    private var speedSamples: [UUID: (Date, Int64)] = [:]
    private var inboundIDs: [String: UUID] = [:]
    private var lastInboundEmit: [String: Date] = [:]
    let hud = HUDController()
    private var inboundFileIds: [UUID: String] = [:]
    private var inboundLastTick: [String: Date] = [:]
    private var controls: [UUID: UploadControl] = [:]
    private var sourceURLs: [UUID: URL] = [:]
    private var peerOfTransfer: [UUID: Peer] = [:]
    private var pendingPinTransferID: UUID?
    private var lastFileSignature = ""

    init() {
        let cfg = Config.shared
        deviceName = cfg.name
        pinEnabled = cfg.pinEnabled
        pin = cfg.pin
        inboxPath = cfg.inbox.path
        if let data = UserDefaults.standard.data(forKey: "landrop.peerPins"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            peerPins = dict
        }
    }

    // MARK: - 生命周期

    func start() {
        hud.attach(model: self)
        guard !isRunning else { return }
        store.onReceive = { [weak self] item in
            guard let self else { return }
            self.files.insert(item, at: 0)
            self.playSound()
            self.toast = "收到 \(item.name)"
            self.refreshFiles()
        }
        server.onUploadAborted = { [weak self] fileId in
            DispatchQueue.main.async {
                guard let self, let id = self.inboundIDs[fileId] else { return }
                self.finishTransfer(id, state: .failed, error: "对端已取消")
                self.inboundIDs.removeValue(forKey: fileId)
                self.inboundFileIds.removeValue(forKey: id)
                self.inboundLastTick.removeValue(forKey: fileId)
                self.toast = "对端取消了传输"
            }
        }
        server.onUploadProgress = { [weak self] fileId, name, received, total in
            guard let self else { return }
            let id: UUID
            if let existing = self.inboundIDs[fileId] {
                id = existing
            } else {
                var transfer = Transfer(fileName: name, peerName: "远端设备", direction: .receive)
                transfer.total = total
                self.transfers.insert(transfer, at: 0)
                id = transfer.id
                self.inboundIDs[fileId] = id
                self.inboundFileIds[id] = fileId
            }
            let now = Date()
            self.inboundLastTick[fileId] = now
            let finished = total == 0 || received >= total
            if finished || now.timeIntervalSince(self.lastInboundEmit[fileId] ?? .distantPast) > 0.12 {
                self.lastInboundEmit[fileId] = now
                self.updateTransfer(id, sent: received, total: total)
            }
            if finished {
                self.finishTransfer(id, state: .done)
                self.inboundIDs.removeValue(forKey: fileId)
                self.inboundFileIds.removeValue(forKey: id)
            }
        }
        guard let bound = server.start(preferredPort: Config.shared.port) else {
            statusText = "启动失败：端口 47823-47832 全部被占用"
            toast = statusText
            return
        }
        port = bound
        isRunning = true
        statusText = "\(Net.primaryIP()):\(bound)"

        discovery.onAnnounce = { [weak self] beacon, ip in
            self?.upsert(beacon, ip: ip)
        }
        discovery.start()
        discovery.probe()
        refreshFiles()

        let prune = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prunePeers() }
        }
        let refresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFiles() }
        }
        // 看门狗：接收侧超过 15s 没有任何字节，判定对端已断开
        let watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStalledInbound() }
        }
        timers = [prune, refresh, watchdog]
    }

    func stop() {
        discovery.stop()
        server.stop()
        isRunning = false
        statusText = "已停止"
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        peers.removeAll()
    }

    func toggleServer() { isRunning ? stop() : start() }

    func probeNow() {
        discovery.probe()
        refreshFiles()
    }

    // MARK: - 设备

    private func upsert(_ beacon: Beacon, ip: String) {
        let platform = PlatformKind(raw: beacon.platform)
        if let idx = peers.firstIndex(where: { $0.id == beacon.id }) {
            peers[idx].name = beacon.name
            peers[idx].platform = platform
            peers[idx].host = ip
            peers[idx].port = beacon.port
            peers[idx].pinRequired = beacon.pin_required
            peers[idx].lastSeen = Date()
        } else {
            peers.append(Peer(id: beacon.id, name: beacon.name, platform: platform,
                              host: ip, port: beacon.port, pinRequired: beacon.pin_required))
        }
        peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func prunePeers() {
        let before = peers.count
        peers.removeAll { !$0.isOnline }
        if peers.count != before { return }
    }

    func addManual(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "http://", with: "")
        var parts = trimmed.split(separator: ":")
        var portPart = 47823
        if parts.count == 2, let p = Int(parts[1]) { portPart = p; parts = [parts[0]] }
        guard let h = parts.first, !h.isEmpty else { toast = "地址格式应为 192.168.1.5[:端口]"; return }
        let hostName = String(h)
        Task {
            let temp = Peer(id: "manual-\(hostName)-\(portPart)", name: hostName,
                            platform: .unknown, host: hostName, port: portPart, pinRequired: false)
            do {
                let info = try await PeerClient(pin: pinFor(temp)).info(temp)
                let beacon = Beacon(type: "announce",
                                    id: info["id"] as? String ?? temp.id,
                                    name: info["name"] as? String ?? hostName,
                                    platform: info["platform"] as? String ?? "unknown",
                                    port: (info["port"] as? NSNumber)?.intValue ?? portPart,
                                    pinRequired: info["pin_required"] as? Bool ?? false)
                upsert(beacon, ip: hostName)
                toast = "已连接 \(beacon.name)"
            } catch {
                toast = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 收件箱

    func refreshFiles() {
        let listed = store.list()
        let signature = listed.map { "\($0.id)-\($0.size)" }.joined(separator: ",")
        if signature != lastFileSignature {
            lastFileSignature = signature
            files = listed
        }
    }

    func open(_ item: FileItem) {
        guard let url = item.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: FileItem) {
        guard let url = item.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func delete(_ item: FileItem) {
        store.delete(item)
        files.removeAll { $0.id == item.id }
        lastFileSignature = ""
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: - 发送

    func pickAndSend(to peer: Peer) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要发送给 \(peer.name) 的文件"
        panel.prompt = "发送"
        if panel.runModal() == .OK {
            send(urls: panel.urls, to: peer)
        }
    }

    func send(urls: [URL], to peer: Peer) {
        guard !urls.isEmpty else { return }
        for url in urls {
            var transfer = Transfer(fileName: url.lastPathComponent,
                                    peerName: peer.name,
                                    direction: .send)
            transfer.total = fileSize(url)
            transfers.insert(transfer, at: 0)
            let id = transfer.id
            let control = UploadControl()
            controls[id] = control
            sourceURLs[id] = url
            peerOfTransfer[id] = peer
            runUpload(id: id, url: url, peer: peer, control: control)
        }
    }

    private func runUpload(id: UUID, url: URL, peer: Peer, control: UploadControl) {
        Task {
            let outcome = await PeerClient(pin: pinFor(peer)).upload(file: url, to: peer, control: control) { sent, total in
                Task { @MainActor in self.updateTransfer(id, sent: sent, total: total) }
            }
            switch outcome {
            case .done:
                finishTransfer(id, state: .done)
                toast = "已发送 \(url.lastPathComponent)"
                cleanupTransfer(id)
            case .paused:
                finishTransfer(id, state: .paused)
            case .cancelled:
                finishTransfer(id, state: .cancelled, error: "已取消")
                cleanupTransfer(id)
            case .failed:
                finishTransfer(id, state: .failed, error: "发送失败")
                cleanupTransfer(id)
            case .pinRequired:
                finishTransfer(id, state: .failed, error: "需要配对码")
                // 保留 control/sourceURL，输入配对码后可以原地重试
                pendingPinTransferID = id
                pendingPinPeer = peer
                toast = "「\(peer.name)」需要配对码"
            }
        }
    }

    /// 配对码保存后重试刚才被 401 拒绝的上传
    func retryAfterPin(_ peer: Peer) {
        guard let id = pendingPinTransferID,
              controls[id] != nil,
              let url = sourceURLs[id],
              let target = peerOfTransfer[id], target.id == peer.id else { return }
        pendingPinTransferID = nil
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].state = .running
        transfers[idx].error = nil
        if let control = controls[id] {
            control.pauseRequested = false
            control.cancelRequested = false
            runUpload(id: id, url: url, peer: target, control: control)
        }
    }

    func pause(_ t: Transfer) { controls[t.id]?.pauseRequested = true }

    func resume(_ t: Transfer) {
        guard let control = controls[t.id],
              let url = sourceURLs[t.id],
              let peer = peerOfTransfer[t.id] else { return }
        control.pauseRequested = false
        control.cancelRequested = false
        if let idx = transfers.firstIndex(where: { $0.id == t.id }) {
            transfers[idx].state = .running
            transfers[idx].error = nil
        }
        runUpload(id: t.id, url: url, peer: peer, control: control)
    }

    /// 发送/接收统一取消入口（HUD 与列表共用）
    func cancelTransfer(_ t: Transfer) {
        if t.direction == .send {
            cancel(t)
        } else {
            cancelInbound(t)
        }
    }

    private func cancelInbound(_ t: Transfer) {
        guard let fileId = inboundFileIds[t.id] else { return }
        server.cancelInbound(fileId: fileId)
        finishTransfer(t.id, state: .cancelled, error: "已取消接收")
        inboundIDs.removeValue(forKey: fileId)
        inboundFileIds.removeValue(forKey: t.id)
    }

    func cancel(_ t: Transfer) {
        guard let control = controls[t.id] else {
            finishTransfer(t.id, state: .cancelled, error: "已取消")
            return
        }
        control.cancelRequested = true
        // 暂停/失败状态下没有正在跑的上传循环，必须就地结束，否则会永远卡住
        if t.state != .running {
            finishTransfer(t.id, state: .cancelled, error: "已取消")
            cleanupTransfer(t.id)
        }
        if let peer = peerOfTransfer[t.id] {
            let fileId = control.fileId
            let pin = pinFor(peer)
            Task.detached {
                try? await PeerClient(pin: pin).cancelUpload(peer: peer, fileId: fileId)
            }
        }
    }

    private func cleanupTransfer(_ id: UUID) {
        controls[id] = nil
        sourceURLs[id] = nil
        peerOfTransfer[id] = nil
    }

    func sendText(_ text: String, to peer: Peer) {
        guard !text.isEmpty else { return }
        var transfer = Transfer(fileName: "文本 \(text.count) 字", peerName: peer.name, direction: .send)
        transfer.total = Int64(text.utf8.count)
        transfer.sent = transfer.total
        transfer.state = .running
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        Task {
            do {
                try await PeerClient(pin: pinFor(peer)).sendText(text, name: nil, to: peer)
                finishTransfer(id, state: .done)
                toast = "文本已发送给 \(peer.name)"
            } catch {
                if let pe = error as? PeerError, case .pin = pe {
                    pendingPinPeer = peer
                    toast = "「\(peer.name)」需要配对码"
                }
                finishTransfer(id, state: .failed, error: error.localizedDescription)
            }
        }
    }

    func sendClipboard(to peer: Peer) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { toast = "剪贴板里没有文本"; return }
        sendText(text, to: peer)
    }

    // MARK: - 拉取

    func download(_ remote: RemoteFile, from peer: Peer) {
        var transfer = Transfer(fileName: remote.name, peerName: peer.name, direction: .receive)
        transfer.total = remote.size
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        let dir = Config.shared.inbox
        Task {
            do {
                let url = try await PeerClient(pin: pinFor(peer))
                    .download(remote, from: peer, to: dir) { got, total in
                        Task { @MainActor in self.updateTransfer(id, sent: got, total: total) }
                    }
                finishTransfer(id, state: .done)
                toast = "已保存 \(url.lastPathComponent)"
                refreshFiles()
            } catch {
                if let pe = error as? PeerError, case .pin = pe {
                    pendingPinPeer = peer
                    toast = "「\(peer.name)」需要配对码"
                }
                finishTransfer(id, state: .failed, error: error.localizedDescription)
            }
        }
    }

    private func checkStalledInbound() {
        let now = Date()
        for (fileId, last) in inboundLastTick {
            guard now.timeIntervalSince(last) > 6 else { continue }
            guard let id = inboundIDs[fileId] else {
                inboundLastTick.removeValue(forKey: fileId)
                continue
            }
            server.cancelInbound(fileId: fileId)
            finishTransfer(id, state: .failed, error: "连接超时")
            inboundIDs.removeValue(forKey: fileId)
            inboundFileIds.removeValue(forKey: id)
            inboundLastTick.removeValue(forKey: fileId)
            toast = "传输已中断（6s 无数据）"
        }
    }

    // MARK: - 配对码

    func pinFor(_ peer: Peer) -> String? {
        if !peer.pinRequired { return nil }
        return peerPins[peer.id]
    }

    func setPin(_ value: String, for peer: Peer) {
        peerPins[peer.id] = value
        if let data = try? JSONEncoder().encode(peerPins) {
            UserDefaults.standard.set(data, forKey: "landrop.peerPins")
        }
    }

    func peer(by id: String?) -> Peer? {
        guard let id else { return nil }
        return peers.first { $0.id == id }
    }

    // MARK: - 设置

    func applySettings() {
        let cfg = Config.shared
        let nameChanged = cfg.name != deviceName
        cfg.name = deviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "Mac" : deviceName
        cfg.pinEnabled = pinEnabled
        cfg.pin = pin
        if cfg.inbox.path != inboxPath {
            cfg.inbox = URL(fileURLWithPath: inboxPath, isDirectory: true)
            store.inbox = cfg.inbox
            refreshFiles()
        }
        if nameChanged && isRunning { discovery.probe() }
    }

    func regeneratePin() {
        pin = Config.randomPin()
        Config.shared.pin = pin
    }

    func pickInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: inboxPath)
        if panel.runModal() == .OK, let url = panel.url {
            inboxPath = url.path
            applySettings()
        }
    }

    func revealInbox() {
        NSWorkspace.shared.open(Config.shared.inbox)
    }

    // MARK: - 杂项

    private func updateTransfer(_ id: UUID, sent: Int64, total: Int64) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        var t = transfers[idx]
        let now = Date()
        if let sample = speedSamples[id] {
            let dt = now.timeIntervalSince(sample.0)
            if dt >= 0.2 {
                let inst = Double(max(0, sent - sample.1)) / dt
                let prev = t.speedBps
                t.speedBps = prev > 1 ? prev * 0.6 + inst * 0.4 : inst
                speedSamples[id] = (now, sent)
            }
        } else {
            speedSamples[id] = (now, sent)
        }
        t.sent = sent
        if total > 0 { t.total = total }
        transfers[idx] = t
    }

    private func finishTransfer(_ id: UUID, state: TransferState, error: String? = nil) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[idx].state = state
        transfers[idx].error = error
        transfers[idx].speedBps = 0
        speedSamples[id] = nil
        if state == .done { transfers[idx].sent = transfers[idx].total }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
    }

    private func playSound() {
        NSSound(named: "Glass")?.play()
    }
}
