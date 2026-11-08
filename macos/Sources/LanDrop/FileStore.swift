import Foundation
import UniformTypeIdentifiers

/// 收件箱：落地接收到的文件与文本，提供列表/查找/重名处理
final class FileStore {
    private let lock = NSLock()
    private let mutationLock = NSLock()
    private let queue = DispatchQueue(label: "landrop.store")

    private var _inbox: URL

    var onReceive: ((FileItem) -> Void)?

    init(inbox: URL) {
        _inbox = inbox
        ensureDirs()
    }

    var inbox: URL {
        get { lock.lock(); defer { lock.unlock() }; return _inbox }
        set {
            lock.lock(); _inbox = newValue; lock.unlock()
            ensureDirs()
        }
    }

    var partialDir: URL { inbox.appendingPathComponent(".lan-drop-partials", isDirectory: true) }

    private func ensureDirs() {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: partialDir, withIntermediateDirectories: true)
    }

    // MARK: - 列表

    func list() -> [FileItem] {
        queue.sync { _listLocked() }
    }

    private func _listLocked() -> [FileItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [FileItem] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date()
            let ext = url.pathExtension.lowercased()
            items.append(
                FileItem(
                    id: HexID.stable(name),
                    name: name,
                    size: size,
                    mime: mimeType(for: url),
                    mtime: mtime,
                    kind: ext == "txt" ? "text" : "file",
                    localURL: url
                )
            )
        }
        return items.sorted { $0.mtime > $1.mtime }
    }

    func url(for id: String) -> URL? {
        list().first { $0.id == id }?.localURL
    }

    // MARK: - 接收

    struct UploadSession {
        let fileId: String
        let partURL: URL
        let finalName: String
    }

    /// 打开上传会话：返回会话与已接收字节数（用于断点续传）
    func beginUpload(fileId: String, rawName: String) throws -> (UploadSession, Int64) {
        mutationLock.lock(); defer { mutationLock.unlock() }
        ensureDirs()
        let safe = sanitize(rawName)
        let finalName = uniqueName(for: safe)
        let part = partURL(for: fileId)
        let existing = fileSize(part)
        return (UploadSession(fileId: fileId, partURL: part, finalName: finalName), existing)
    }

    func partSize(fileId: String) -> Int64 {
        mutationLock.lock(); defer { mutationLock.unlock() }
        return fileSize(partURL(for: fileId))
    }

    /// fileId 来自请求头，不能直接拼进路径；清理后附加稳定哈希保证唯一
    private func partURL(for fileId: String) -> URL {
        let safe = fileId.map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") { return ch }
            return "_"
        }
        let prefix = String(safe.prefix(64))
        return partialDir.appendingPathComponent(prefix + "-" + HexID.stable(fileId) + ".part")
    }

    /// 落盘：把 .part 原子移动到收件箱
    func finishUpload(_ session: UploadSession) throws -> FileItem {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let fm = FileManager.default
        var target = inbox.appendingPathComponent(session.finalName)
        if fm.fileExists(atPath: target.path) {
            target = inbox.appendingPathComponent(uniqueName(for: session.finalName))
        }
        try fm.moveItem(at: session.partURL, to: target)
        let size = fileSize(target)
        let item = FileItem(
            id: HexID.stable(target.lastPathComponent),
            name: target.lastPathComponent,
            size: size,
            mime: mimeType(for: target),
            mtime: Date(),
            kind: target.pathExtension.lowercased() == "txt" ? "text" : "file",
            localURL: target
        )
        DispatchQueue.main.async { self.onReceive?(item) }
        return item
    }

    func saveText(_ text: String, name: String?) -> FileItem {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let title = name?.isEmpty == false ? sanitize(name!) : "文本-\(timestamp()).txt"
        let fileName = title.lowercased().hasSuffix(".txt") ? title : title + ".txt"
        let target = inbox.appendingPathComponent(uniqueName(for: fileName))
        try? text.data(using: .utf8)?.write(to: target)
        let item = FileItem(
            id: HexID.stable(target.lastPathComponent),
            name: target.lastPathComponent,
            size: Int64(text.utf8.count),
            mime: "text/plain",
            mtime: Date(),
            kind: "text",
            localURL: target
        )
        DispatchQueue.main.async { self.onReceive?(item) }
        return item
    }

    func delete(_ item: FileItem) {
        guard let url = item.localURL else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - 命名

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    func sanitize(_ raw: String) -> String {
        // 调用方（HTTPServer）已经按协议解码过一次，这里只做安全清理
        var s = raw
        s = s.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        // 去掉控制字符
        s = String(s.unicodeScalars.filter { !($0.value < 0x20 || $0.value == 0x7f) })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "..", with: "_")
        if s.isEmpty { s = "未命名-\(timestamp())" }
        // 限制 200 字节（不截断 UTF-8 字符）
        if s.utf8.count > 200 {
            var out = ""
            for ch in s {
                if (out + String(ch)).utf8.count > 200 { break }
                out.append(ch)
            }
            s = out
        }
        return s
    }

    func uniqueName(for name: String) -> String {
        let fm = FileManager.default
        var candidate = name
        if !fm.fileExists(atPath: inbox.appendingPathComponent(candidate).path) { return candidate }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var i = 1
        while true {
            candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !fm.fileExists(atPath: inbox.appendingPathComponent(candidate).path) { return candidate }
            i += 1
            if i > 9999 { return "\(UUID().uuidString).\(ext)" }
        }
    }

    func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let m = type.preferredMIMEType {
            return m
        }
        return "application/octet-stream"
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }

    func freeSpace() -> Int64 {
        let values = try? inbox.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
