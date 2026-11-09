import Foundation
import ServiceManagement

/// 登录时自动启动（macOS 13+ 的 SMAppService）
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 返回错误描述；nil 表示设置成功
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
