import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                DevicesPane()
                    .frame(minWidth: 330, idealWidth: 390, maxWidth: 520)
                InboxPane()
                    .frame(minWidth: 460)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { toastView }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showNFCSticker) {
            NFCStickerSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showTextComposer) {
            TextComposerSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.manualAdd) {
            ManualAddSheet().environmentObject(model)
        }
        .sheet(item: $model.browsePeer) { peer in
            BrowsePeerSheet(peer: peer).environmentObject(model)
        }
        .sheet(item: $model.pendingPinPeer) { peer in
            PinSheet(peer: peer).environmentObject(model)
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.29, green: 0.55, blue: 1.0),
                                                  Color(red: 0.55, green: 0.35, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(model.deviceName)
                    .font(.system(size: 20, weight: .bold))
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isRunning ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(model.isRunning ? model.statusText : "未启动")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if model.pinEnabled {
                        Label(model.pin, systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Button {
                model.showNFCSticker = true
            } label: {
                Label("贴纸", systemImage: "wave.3.right")
            }
            .help("NFC 贴纸：手机碰一下就发到这台 Mac")

            Button {
                model.showTextComposer = true
            } label: {
                Label("发送文本", systemImage: "text.bubble")
            }
            .disabled(model.peers.isEmpty)

            Button {
                if let peer = model.peer(by: model.selectedPeerID) {
                    model.pickAndSend(to: peer)
                } else {
                    model.toast = "先在左侧选一台设备"
                }
            } label: {
                Label("发送文件", systemImage: "paperplane.fill")
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button {
                model.toggleServer()
            } label: {
                Label(model.isRunning ? "停止" : "启动",
                      systemImage: model.isRunning ? "stop.circle" : "play.circle")
            }

            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: 底栏

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label("\(model.peers.count) 台设备", systemImage: "wifi")
            Label("\(model.files.count) 个文件", systemImage: "tray.full")
            if !model.transfers.filter({ $0.state == .running }).isEmpty {
                Label("\(model.transfers.filter { $0.state == .running }.count) 个传输中",
                      systemImage: "arrow.up.arrow.down.circle")
            }
            Spacer()
            Button("打开收件箱") { model.revealInbox() }
                .buttonStyle(.link)
            Text("LanDrop 2.0 · 端口 \(model.port == 0 ? 47823 : model.port)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .foregroundStyle(.white)
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation { model.toast = nil }
                }
        }
    }
}

// MARK: - 设备列表

struct DevicesPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("附近设备").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    model.probeNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新搜索")

                Button {
                    model.manualAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("手动输入 IP")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.peers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("还没有发现设备").font(.system(size: 13, weight: .medium))
                    Text("确认对方已打开 LanDrop，且与本机在同一 Wi-Fi。\n也可以点右上角 + 手动输入 IP。")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.peers) { peer in
                            PeerRow(peer: peer)
                                .onTapGesture { model.selectedPeerID = peer.id }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

struct PeerRow: View {
    @EnvironmentObject var model: AppModel
    let peer: Peer
    @State private var targeted = false
    @State private var hovered = false

    private var selected: Bool { model.selectedPeerID == peer.id }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: peer.platform.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if peer.pinRequired {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                Text("\(peer.platform.label) · \(peer.endpoint)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                if hovered || selected {
                    Button {
                        model.sendClipboard(to: peer)
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("发送剪贴板文本")

                    Button {
                        model.pickAndSend(to: peer)
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .frame(width: 17, height: 17)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("发送文件")
                }

                Menu {
                    Button("发送文件…") { model.pickAndSend(to: peer) }
                    Button("发送剪贴板文本") { model.sendClipboard(to: peer) }
                    Button("浏览对方文件…") { model.browsePeer = peer }
                    Divider()
                    Button("测试连通性") {
                        Task { _ = try? await PeerClient(pin: model.pinFor(peer)).info(peer) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 17, height: 17)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(targeted ? Color.accentColor.opacity(0.18)
                      : (selected ? Color.accentColor.opacity(0.10)
                         : Color(nsColor: .windowBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.16),
                              lineWidth: targeted ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.send(urls: [url], to: peer) }
                }
            }
            return true
        }
        .contextMenu {
            Button("发送文件…") { model.pickAndSend(to: peer) }
            Button("发送剪贴板文本") { model.sendClipboard(to: peer) }
            Button("浏览对方文件…") { model.browsePeer = peer }
        }
    }
}
