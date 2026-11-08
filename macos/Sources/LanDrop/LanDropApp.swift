import SwiftUI
import AppKit

struct LanDropApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LanDrop") {
            RootView()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("发送文件…") {
                    if let peer = model.peer(by: model.selectedPeerID) ?? model.peers.first {
                        model.pickAndSend(to: peer)
                    }
                }
                .keyboardShortcut("o")
                Button("刷新设备") { model.probeNow() }
                    .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
