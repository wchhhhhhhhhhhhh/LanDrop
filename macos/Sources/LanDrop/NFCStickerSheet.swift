import SwiftUI
import AppKit

/// "NFC 贴纸"面板：把**这台 Mac** 的碰一碰信息摊开给用户。
///
/// macOS 没有开放的 NFC 读卡接口，所以 Mac 不能碰贴纸、也写不了贴纸；
/// 这里生成的是"贴纸内容"，由手机端 LanDrop 写入贴纸，之后手机碰贴纸就能发给这台 Mac。
struct NFCStickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var target: LandropTag.Target { model.stickerTarget }
    private var payload: String { LandropTag.uri(target) }
    private var bytes: Int { LandropTag.ndefBytes(target, withAar: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetCard
                    if !model.isRunning { offlineWarning }
                    steps
                    payloadBox
                    if model.pinEnabled { pinNote }
                    footnote
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            Divider()
            footer
        }
        .frame(width: 560, height: 486)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.29, green: 0.55, blue: 1.0),
                                                  Color(red: 0.55, green: 0.35, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "wave.3.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NFC 贴纸")
                    .font(.system(size: 16, weight: .bold))
                Text("手机碰一下这张贴纸，就会把文件发到这台 Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
    }

    // MARK: - 本机信息

    private var targetCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("macOS · \(target.endpoint)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(bytes) 字节")
                    .font(.system(size: 10.5, weight: .medium))
                Text("NTAG213 够用")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var offlineWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text("还没开始接收，贴纸里的地址连不上。先启动接收再写贴纸。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("启动") { model.toggleServer() }
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - 步骤

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("怎么用")
                .font(.system(size: 11, weight: .semibold))
            step(1, "手机打开 LanDrop，点顶部的「贴纸」")
            step(2, "选「\(model.deviceName)」，把空贴纸靠近手机背面写入")
            step(3, "以后在相册/文件里分享给 LanDrop，选「NFC 碰一碰」，碰一下贴纸就开始传输")
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 载荷

    private var payloadBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("贴纸内容")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    copyPayload()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeOut(duration: 0.25)) { copied = false }
                    }
                } label: {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .scaleEffect(copied ? 1.05 : 1)
                        .foregroundStyle(copied ? Color.green : Color.accentColor)
                }
                .controlSize(.small)
            }
            Text(payload)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.secondary.opacity(0.15))
                )
        }
    }

    private var pinNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("已开启配对码：手机碰贴纸后的第一次发送需要输入 6 位配对码，输入一次后那台手机会记住。")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("macOS 没有开放的 NFC 读卡接口，Mac 不能碰贴纸，写入要用手机。贴纸只写设备名、地址和端口，不含配对码；也可以把上面这段粘进任意 NDEF 写入 App（URI 记录）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("约 \(bytes) 字节 · 建议 NTAG213 及以上")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func copyPayload() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(payload, forType: .string)
        model.toast = "贴纸内容已复制"
    }
}
