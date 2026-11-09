import SwiftUI
import AppKit

// MARK: - 收件箱 / 传输

struct InboxPane: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("收件箱").tag(0)
                    Text("传输记录").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()

                Spacer()

                if tab == 0 {
                    Button { model.refreshFiles() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Button { model.revealInbox() } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("清除已结束") { model.clearFinishedTransfers() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if tab == 0 {
                if model.files.isEmpty {
                    emptyState(icon: "tray", title: "收件箱是空的",
                               subtitle: "别人发来的文件会出现在这里，\n也可以直接从这里打开或拖到 Finder。")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.files) { item in
                                FileRow(item: item)
                            }
                        }
                        .padding(12)
                    }
                }
            } else {
                if model.transfers.isEmpty {
                    emptyState(icon: "arrow.up.arrow.down", title: "还没有传输记录",
                               subtitle: "选择左侧设备后点「发送文件」，或把文件拖到设备卡片上。")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.transfers) { t in
                                TransferRow(transfer: t)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let item: FileItem
    @State private var hovered = false

    private var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: item.mtime)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 18))
                .frame(width: 30)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.sizeText) · \(timeText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if hovered {
                Button("打开") { model.open(item) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button {
                    model.reveal(item)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                Button {
                    model.delete(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移到废纸篓")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hovered ? Color.accentColor.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .contextMenu {
            Button("打开") { model.open(item) }
            Button("在 Finder 中显示") { model.reveal(item) }
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.localURL?.path ?? "", forType: .string)
            }
            Divider()
            Button("移到废纸篓") { model.delete(item) }
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject var model: AppModel
    let transfer: Transfer
    @State private var hovered = false
    @State private var copied = false
    @State private var copyToken = 0

    private var canActOnFile: Bool {
        transfer.state == .done && transfer.localURL != nil
    }

    private func copyFile() {
        model.copyFile(transfer)
        copyToken += 1
        let token = copyToken
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard token == copyToken else { return }
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }

    private var color: Color {
        switch transfer.state {
        case .running: return .accentColor
        case .paused: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var statusText: String {
        switch transfer.state {
        case .running:
            return transfer.sent == 0
                ? "准备中…"
                : "\(Int(transfer.progress * 100))% · \(transfer.speedText)"
        case .paused: return "已暂停 · \(Int(transfer.progress * 100))%"
        case .done: return "完成 · \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))"
        case .failed: return transfer.error ?? "失败"
        case .cancelled: return "已取消"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transfer.fileName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(transfer.direction.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.14)))
                        .foregroundStyle(color)
                    Spacer()
                    Text(transfer.peerName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if transfer.direction == .receive && transfer.state == .running {
                        Button("取消") { model.cancelTransfer(transfer) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10.5))
                            .foregroundColor(.red)
                    }
                    if transfer.direction == .send && (transfer.state == .running || transfer.state == .paused) {
                        Button(transfer.state == .paused ? "继续" : "暂停") {
                            if transfer.state == .paused { model.resume(transfer) } else { model.pause(transfer) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                        Button("取消") { model.cancel(transfer) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10.5))
                            .foregroundColor(.red)
                    }
                }

                if transfer.state == .running {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)
                        .tint(color)
                } else {
                    HStack(spacing: 10) {
                        Text(statusText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(transfer.state == .failed ? .red : .secondary)

                        if canActOnFile && hovered {
                            Button(copied ? "已复制" : "复制") { copyFile() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(copied ? Color.green : Color.accentColor)
                                .scaleEffect(copied ? 1.08 : 1)
                                .help("复制文件，可直接粘贴到 Finder")

                            Button("打开位置") { model.revealFile(transfer) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5))
                                .help("在 Finder 中显示")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hovered
                      ? Color.accentColor.opacity(0.07)
                      : Color(nsColor: .windowBackgroundColor).opacity(0.7))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            if canActOnFile {
                Button("复制文件") { copyFile() }
                Button("在 Finder 中显示") { model.revealFile(transfer) }
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transfer.localURL?.path ?? "", forType: .string)
                }
                Divider()
            }
            Button("拷贝文件名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transfer.fileName, forType: .string)
            }
        }
    }
}

// MARK: - 发送文本

struct TextComposerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var peerID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送文本").font(.system(size: 16, weight: .bold))
            Text("文本会落成 .txt 存进对方收件箱，适合传链接、验证码、一段配置。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Picker("发送到", selection: $peerID) {
                ForEach(model.peers) { peer in
                    Text("\(peer.name)（\(peer.platform.label)）").tag(peer.id)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))

            HStack {
                Button("粘贴剪贴板") {
                    text = NSPasteboard.general.string(forType: .string) ?? text
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("发送") {
                    if let peer = model.peers.first(where: { $0.id == peerID }) {
                        model.sendText(text, to: peer)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty || peerID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if peerID.isEmpty {
                peerID = model.selectedPeerID ?? model.peers.first?.id ?? ""
            }
        }
    }
}

// MARK: - 浏览对方文件

struct BrowsePeerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: Peer

    @State private var files: [RemoteFile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: peer.platform.symbol).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.name).font(.system(size: 14, weight: .bold))
                    Text(peer.endpoint).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            Divider()

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取对方收件箱…").font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("重试") { load() }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if files.isEmpty {
                Text("对方收件箱是空的").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files) { f in
                            HStack(spacing: 10) {
                                Image(systemName: "doc").frame(width: 24).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    model.download(f, from: peer)
                                } label: {
                                    Label("下载", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .frame(height: 300)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { load() }
    }

    private func load() {
        loading = true
        error = nil
        Task {
            do {
                let listed = try await PeerClient(pin: model.pinFor(peer)).listFiles(peer)
                await MainActor.run {
                    files = listed
                    loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = (error as? PeerError)?.errorDescription ?? error.localizedDescription
                    loading = false
                }
            }
        }
    }
}

// MARK: - 配对码

struct PinSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: Peer

    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入配对码").font(.system(size: 16, weight: .bold))
            Text("「\(peer.name)」开启了配对码保护，请输入对方 LanDrop 窗口顶部显示的 6 位数字。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6 位数字", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18, design: .monospaced))
                .frame(width: 180)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    model.setPin(value, for: peer)
                    model.retryAfterPin(peer)
                    model.toast = "配对码已保存"
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.count != 6)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 手动添加

struct ManualAddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动连接").font(.system(size: 16, weight: .bold))
            Text("局域网广播被拦截时，直接输入对方窗口顶部显示的 IP（可带端口）。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("192.168.1.23 或 192.168.1.23:47823", text: $host)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("连接") {
                    model.addManual(host: host)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 设置

struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDonate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                Section("本机") {
                    TextField("设备名", text: $model.deviceName)
                    HStack {
                        TextField("收件箱", text: $model.inboxPath)
                        Button("选择…") { model.pickInbox() }
                    }
                    HStack {
                        Text("监听地址")
                        Spacer()
                        Text("\(Net.primaryIP()):\(model.port == 0 ? 47823 : model.port)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("启动") {
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Text("登录 macOS 后自动打开 LanDrop，方便随时接收文件。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Section("安全") {
                    Toggle("启用配对码（对方发送前需输入）", isOn: $model.pinEnabled)
                    HStack {
                        Text("当前配对码")
                        Spacer()
                        Text(model.pin)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("换一个") { model.regeneratePin() }
                    }
                    Text("协议为明文 HTTP，配对码只用于防误触，不加密内容。仅建议在可信局域网使用。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("LanDrop 2.0.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("协议")
                        Spacer()
                        Text("UDP 47824 发现 · HTTP \(model.port == 0 ? 47823 : model.port) 传输")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showDonate = true
                    } label: {
                        HStack {
                            Label("自愿捐赠", systemImage: "heart.fill")
                                .foregroundStyle(.pink)
                            Spacer()
                            Text("微信")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("完成") {
                    model.applySettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 520)
        .sheet(isPresented: $showDonate) {
            DonateSheet()
        }
    }
}

// MARK: - 自愿捐赠

struct DonateSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var qrImage: NSImage? {
        guard let url = Bundle.module.url(forResource: "donate-wechat", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("自愿捐赠")
                .font(.system(size: 20, weight: .bold))
            Text("LanDrop 免费、无广告、不登录、不上传云端。\n如果它帮到了你，可以自愿捐赠；不捐赠不影响任何功能。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qrImage {
                Image(nsImage: qrImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 410)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 300, height: 410)
                    .overlay(Text("收款码资源缺失").foregroundStyle(.secondary))
            }

            Text("收款方：皓子(**皓) · 微信支付")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("捐赠完全自愿，请量力而行。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 420)
    }
}
