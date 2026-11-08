import SwiftUI
import AppKit
import Combine

/// 桌面右上角置顶传输浮窗：显示进度 / 速度，可直接取消
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var hideWork: DispatchWorkItem?
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
            show(with: transfers)
        } else if panel?.isVisible == true {
            // 结束后停留 2.5s 让用户看到「已完成」
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !(self.model?.transfers.contains { $0.state == .running } ?? false) {
                    self.hide()
                }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
            show(with: transfers)
        }
    }

    private func show(with transfers: [Transfer]) {
        let panel = ensurePanel()
        let view = HUDView(model: model!, transfers: transfers)
        let host = NSHostingView(rootView: view)
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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
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
        Array(transfers.filter { $0.state != .running && $0.state != .paused }.prefix(1))
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

    private var isActive: Bool { transfer.state == .running || transfer.state == .paused }

    private var statusText: String {
        switch transfer.state {
        case .running: return "\(Int(transfer.progress * 100))% · \(transfer.speedText)"
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
        }
    }
}
