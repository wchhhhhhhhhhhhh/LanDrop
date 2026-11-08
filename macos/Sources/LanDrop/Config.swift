import Foundation
import Security

/// 全局配置：设备身份 + 端口 + 收件箱 + 配对码
final class Config {
    static let shared = Config()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    private(set) var deviceID: String

    private var _name: String
    private var _port: Int
    private var _pinEnabled: Bool
    private var _pin: String
    private var _inbox: URL

    private init() {
        if let saved = defaults.string(forKey: "landrop.deviceID"), saved.count == 16 {
            deviceID = saved
        } else {
            let id = HexID.random(bytes: 8)
            defaults.set(id, forKey: "landrop.deviceID")
            deviceID = id
        }

        let hostName = Host.current().localizedName ?? "Mac"
        _name = defaults.string(forKey: "landrop.name") ?? "\(hostName)"

        let p = defaults.integer(forKey: "landrop.port")
        _port = p == 0 ? 47823 : p

        _pinEnabled = defaults.bool(forKey: "landrop.pinEnabled")
        _pin = defaults.string(forKey: "landrop.pin") ?? Config.randomPin()

        if let path = defaults.string(forKey: "landrop.inbox"), !path.isEmpty {
            _inbox = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            _inbox = downloads.appendingPathComponent("LanDrop", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: _inbox, withIntermediateDirectories: true)
    }

    /// 调试用：同一台机器跑多个实例时区分设备身份
    func overrideDeviceID(_ id: String) {
        guard id.count >= 4 else { return }
        deviceID = id
    }

    static func randomPin() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    var name: String {
        get { lock.lock(); defer { lock.unlock() }; return _name }
        set { lock.lock(); _name = newValue; lock.unlock(); defaults.set(newValue, forKey: "landrop.name") }
    }

    var port: Int {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock(); defaults.set(newValue, forKey: "landrop.port") }
    }

    var pinEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _pinEnabled }
        set { lock.lock(); _pinEnabled = newValue; lock.unlock(); defaults.set(newValue, forKey: "landrop.pinEnabled") }
    }

    var pin: String {
        get { lock.lock(); defer { lock.unlock() }; return _pin }
        set { lock.lock(); _pin = newValue; lock.unlock(); defaults.set(newValue, forKey: "landrop.pin") }
    }

    var inbox: URL {
        get { lock.lock(); defer { lock.unlock() }; return _inbox }
        set {
            lock.lock(); _inbox = newValue; lock.unlock()
            defaults.set(newValue.path, forKey: "landrop.inbox")
            try? FileManager.default.createDirectory(at: newValue, withIntermediateDirectories: true)
        }
    }

    /// 实际监听端口（首选项端口被占用时自动 +1）
    private var _activePort: Int = 0
    var activePort: Int {
        get { lock.lock(); defer { lock.unlock() }; return _activePort == 0 ? _port : _activePort }
        set { lock.lock(); _activePort = newValue; lock.unlock() }
    }
}
