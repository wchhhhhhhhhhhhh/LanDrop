import Foundation
import Security

// MARK: - 平台

enum PlatformKind: String, Codable {
    case macos, android, harmony, cli, unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "macos", "mac", "osx": self = .macos
        case "android": self = .android
        case "harmony", "harmonyos", "ohos", "hmos": self = .harmony
        case "cli": self = .cli
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .macos: return "macOS"
        case .android: return "Android"
        case .harmony: return "HarmonyOS"
        case .cli: return "命令行"
        case .unknown: return "未知设备"
        }
    }

    var symbol: String {
        switch self {
        case .macos: return "laptopcomputer"
        case .android: return "candybarphone"
        case .harmony: return "iphone.gen3"
        case .cli: return "terminal"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - 发现报文

struct Beacon: Codable, Equatable {
    var app = "landrop"
    var v = 1
    var type: String            // probe | announce
    var id: String
    var name: String
    var platform: String
    var port: Int
    var pin_required: Bool

    enum CodingKeys: String, CodingKey {
        case app, v, type, id, name, platform, port
        case pin_required
    }

    init(type: String, id: String, name: String, platform: String, port: Int, pinRequired: Bool) {
        self.type = type
        self.id = id
        self.name = name
        self.platform = platform
        self.port = port
        self.pin_required = pinRequired
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? c.decode(String.self, forKey: .app)) ?? "landrop"
        v = (try? c.decode(Int.self, forKey: .v)) ?? 1
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? "未知设备"
        platform = (try? c.decode(String.self, forKey: .platform)) ?? "unknown"
        port = (try? c.decode(Int.self, forKey: .port)) ?? 47823
        pin_required = (try? c.decode(Bool.self, forKey: .pin_required)) ?? false
    }
}

// MARK: - 对端

struct Peer: Identifiable, Equatable {
    var id: String
    var name: String
    var platform: PlatformKind
    var host: String
    var port: Int
    var pinRequired: Bool
    var lastSeen: Date = Date()

    var isOnline: Bool { Date().timeIntervalSince(lastSeen) < 30 }

    var baseURL: URL {
        URL(string: "http://\(host):\(port)") ?? URL(string: "http://127.0.0.1:\(port)")!
    }

    var endpoint: String { "\(host):\(port)" }
}

// MARK: - 文件

struct FileItem: Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
    var mime: String
    var mtime: Date
    var kind: String          // file | text
    var localURL: URL?

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    var symbol: String {
        if kind == "text" { return "text.alignleft" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm": return "film"
        case "mp3", "wav", "flac", "aac", "m4a": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "app", "dmg", "pkg": return "shippingbox"
        default: return "doc"
        }
    }
}

// MARK: - 传输任务

enum TransferDirection: String {
    case send, receive
    var label: String { self == .send ? "发送" : "接收" }
}

enum TransferState: String {
    case running, paused, done, failed, cancelled
}

struct Transfer: Identifiable {
    var id = UUID()
    var fileName: String
    var peerName: String
    var direction: TransferDirection
    /// 落到本机磁盘上的文件：接收完成时是收件箱里的文件，发送时是源文件
    var localURL: URL?
    var sent: Int64 = 0
    var total: Int64 = 0
    var state: TransferState = .running
    var error: String?
    var startedAt = Date()
    var speedBps: Double = 0

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(sent) / Double(total))
    }

    var speedText: String {
        if speedBps > 1 {
            return ByteCountFormatter.string(fromByteCount: Int64(speedBps), countStyle: .file) + "/s"
        }
        let elapsed = max(0.2, Date().timeIntervalSince(startedAt))
        let bps = Double(sent) / elapsed
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
}

// MARK: - 远端文件

struct RemoteFile: Identifiable, Hashable {
    var id: String
    var name: String
    var size: Int64
    var mime: String
    var kind: String
}

// MARK: - 工具

enum HexID {
    static func random(bytes: Int = 8) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, bytes, buf.baseAddress!)
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// 由文件名派生的稳定短 ID（用于 /v1/files/{id}/content）
    static func stable(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
