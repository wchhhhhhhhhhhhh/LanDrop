import SwiftUI
import AppKit
import Combine

/// 非激活浮窗默认拿不到第一次点击（按钮要点两下/没反应），这里两个子类一起放开
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 桌面右上角置顶传输浮窗：显示进度 / 速度，可直接取消
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var hideWork: DispatchWorkItem?
    private var hovered = false
    private weak var model: AppModel?

    private let width: CGFloat = 340

    func attach(model: AppModel) {
        self.model = model
        cancellable = model.$transfers
            .receive(on: RunLoop.main)
            .sink { [weak self] transfers in
                self?.sync(transfers)
            }
    }

    private var activeCount: Int {
        (model?.transfers ?? []).filter { $0.state == .running || $0.state == .paused }.count
    }

    private func sync(_ transfers: [Transfer]) {
        let running = transfers.contains { $0.state == .running || $0.state == .paused }
        if running {
            hideWork?.cancel()
            hideWork = nil
            show(with: transfers)
        } else if panel?.isVisible == true {
            // 结束后停留几秒，方便点「复制 / 打开位置」；鼠标在浮窗上时不动
            show(with: transfers)
            scheduleHide(after: 5.0)
        }
    }

    /// 鼠标进入浮窗时暂停自动隐藏，离开后再给 1.2s
    func setHovered(_ value: Bool) {
        hovered = value
        if value {
            hideWork?.cancel()
            hideWork = nil
        } else if !(model?.transfers.contains { $0.state == .running || $0.state == .paused } ?? false) {
            scheduleHide(after: 1.2)
        }
    }

    private func scheduleHide(after seconds: Double) {
        guard !hovered else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func show(with transfers: [Transfer]) {
        let panel = ensurePanel()
        let view = HUDView(model: model!, transfers: transfers)
        let host = HUDHostingView(rootView: view)
        host.frame.size = host.fittingSize
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        panel.contentView = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        var size = host.fittingSize
        size.width = max(width, size.width)
        panel.setContentSize(size)
        position(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 18,
                             y: visible.maxY - size.height - 14)
        panel.setFrameOrigin(origin)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered,
                         defer: false)
        p.level = .screenSaver                    // 压过普通窗口与第三方浮层
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false
        panel = p
        return p
    }
}

// MARK: - 浮窗内容

struct HUDView: View {
    @ObservedObject var model: AppModel
    var transfers: [Transfer]

    private var running: [Transfer] {
        transfers.filter { $0.state == .running || $0.state == .paused }
    }

    private var recent: [Transfer] {
        Array(transfers.filter { $0.state != .running && $0.state != .paused }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(running.isEmpty ? "LanDrop" : "正在传输 \(running.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if running.isEmpty {
                    let last = recent.first
                    let bad = last?.state == .failed || last?.state == .cancelled
                    Image(systemName: bad ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(bad ? Color.red : Color.green)
                }
            }

            ForEach(running.isEmpty ? recent : Array(running.prefix(3))) { t in
                HUDRow(model: model, transfer: t)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .padding(10)
        .onHover { model.hud.setHovered($0) }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)

        )
    }
}

struct HUDRow: View {
    @ObservedObject var model: AppModel
    let transfer: Transfer
    @State private var copied = false
    @State private var copyToken = 0

    private var isActive: Bool { transfer.state == .running || transfer.state == .paused }

    private var statusText: String {
        switch transfer.state {
        case .running:
            return transfer.sent == 0
                ? "准备中…"
                : "\(Int(transfer.progress * 100))% · \(transfer.speedText)"
        case .paused: return "已暂停 · \(Int(transfer.progress * 100))%"
        case .done: return "完成 · \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))"
        case .cancelled: return "已取消"
        case .failed: return transfer.error ?? "失败"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: transfer.direction == .send ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Text(transfer.fileName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isActive {
                    Button {
                        model.cancelTransfer(transfer)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("取消传输")
                }
            }

            if transfer.state == .running {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                    .controlSize(.small)
            }

            HStack {
                Text(transfer.peerName)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(transfer.state == .failed ? .red : .secondary)
            }

            if transfer.state == .done, transfer.localURL != nil {
                HStack(spacing: 10) {
                    Button {
                        model.copyFile(transfer)
                        copyToken += 1
                        let token = copyToken
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                            copied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            guard token == copyToken else { return }
                            withAnimation(.easeOut(duration: 0.25)) { copied = false }
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .scaleEffect(copied ? 1.1 : 1)
                            .foregroundStyle(copied ? Color.green : Color.accentColor)
                    }
                    .help("复制文件，可直接粘贴到 Finder")

                    Button {
                        model.revealFile(transfer)
                    } label: {
                        Label("打开位置", systemImage: "folder")
                    }
                    .help("在 Finder 中显示")
                }
                .font(.system(size: 9.5, weight: .medium))
                .buttonStyle(.borderless)
            }
        }
    }
}
