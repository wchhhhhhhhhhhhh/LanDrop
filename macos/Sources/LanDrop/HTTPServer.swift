import Foundation
import Darwin

enum HTTPError: Error {
    case badRequest(String)
    case tooLarge
    case io
}

// MARK: - 请求

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]   // key 全小写
    var version: String

    static func parse(_ block: String) throws -> HTTPRequest {
        let lines = block.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.isEmpty else { throw HTTPError.badRequest("empty request") }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw HTTPError.badRequest("bad request line") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let qIdx = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIdx])
            let qs = String(target[target.index(after: qIdx)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: path,
                           query: query, headers: headers,
                           version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1")
    }
}

// MARK: - 连接

final class Conn {
    let fd: Int32
    var buf = Data()

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() { Darwin.close(fd) }

    /// 返回 nil 表示对端关闭
    func recvChunk(max: Int = 262_144) -> Data? {
        var tmp = [UInt8](repeating: 0, count: max)
        while true {
            let n = recv(fd, &tmp, max, 0)
            if n > 0 { return Data(bytes: tmp, count: n) }
            if n == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// 读取到 \r\n\r\n 为止的头部
    func readHeaderBlock(limit: Int = 64 * 1024) throws -> String? {
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = buf.range(of: sep) {
                let head = buf.subdata(in: buf.startIndex..<r.lowerBound)
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                return String(decoding: head, as: UTF8.self)
            }
            if buf.count > limit { throw HTTPError.tooLarge }
            guard let chunk = recvChunk() else {
                if buf.isEmpty { return nil }
                throw HTTPError.badRequest("eof in header")
            }
            buf.append(chunk)
        }
    }

    /// 把指定长度的 body 流式写入文件
    func streamBody(length: Int, into handle: FileHandle, onBytes: ((Int) -> Void)? = nil) throws {
        var remaining = length
        if remaining > 0 && !buf.isEmpty {
            let take = min(buf.count, remaining)
            try handle.write(contentsOf: buf.prefix(take))
            buf.removeFirst(take)
            remaining -= take
            onBytes?(take)
        }
        var tmp = [UInt8](repeating: 0, count: 262_144)
        while remaining > 0 {
            let want = min(tmp.count, remaining)
            let n = recv(fd, &tmp, want, 0)
            if n > 0 {
                try handle.write(contentsOf: Data(bytes: tmp, count: n))
                remaining -= n
                onBytes?(n)
            } else if n == 0 {
                throw HTTPError.badRequest("eof in body")
            } else if errno == EINTR {
                continue
            } else {
                throw HTTPError.io
            }
        }
    }

    func readBody(length: Int) throws -> Data {
        var out = Data()
        if !buf.isEmpty {
            let take = min(buf.count, length)
            out.append(buf.prefix(take))
            buf.removeFirst(take)
        }
        while out.count < length {
            guard let chunk = recvChunk(max: min(262_144, length - out.count)) else {
                throw HTTPError.badRequest("eof in body")
            }
            out.append(chunk)
        }
        return out
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = send(fd, base + sent, raw.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw HTTPError.io
                }
            }
        }
    }
}

// MARK: - 服务端

final class HTTPServer {
    private let store: FileStore
    private let config: Config
    private let queue = DispatchQueue(label: "landrop.http", attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var running = false
    private(set) var port: Int = 0

    /// 接收进度回调：(fileId, 文件名, 已收字节, 总字节)
    var onUploadProgress: ((String, String, Int64, Int64) -> Void)?

    /// 上传中断（对端取消/断网）回调
    var onUploadAborted: ((String) -> Void)?

    private var inboundConns: [String: Conn] = [:]
    private var cancelledUploads: [String: Date] = [:]
    private let inboundLock = NSLock()

    private var pinFailures = 0
    private var pinLockedUntil: Date?
    private let pinLock = NSLock()

    init(store: FileStore, config: Config) {
        self.store = store
        self.config = config
    }

    var isRunning: Bool { running }

    // MARK: 生命周期

    @discardableResult
    func start(preferredPort: Int) -> Int? {
        var candidate = preferredPort
        for _ in 0..<10 {
            if let fd = bindAndListen(port: candidate) {
                listenFD = fd
                port = candidate
                config.activePort = candidate
                running = true
                queue.async { [weak self] in self?.acceptLoop() }
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func bindAndListen(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, listen(fd, 64) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in
                self?.handle(fd: clientFD)
            }
        }
    }

    // MARK: 分发

    private func handle(fd: Int32) {
        let conn = Conn(fd: fd)
        defer { conn.close() }
        do {
            guard let head = try conn.readHeaderBlock() else { return }
            let req = try HTTPRequest.parse(head)
            try route(req, conn)
        } catch HTTPError.badRequest(let msg) {
            try? respondError(conn, 400, "bad_request", msg)
        } catch HTTPError.tooLarge {
            try? respondError(conn, 413, "too_large", "请求头过大")
        } catch {
            try? respondError(conn, 500, "internal", "\(error)")
        }
    }

    private func route(_ req: HTTPRequest, _ conn: Conn) throws {
        if req.method == "OPTIONS" {
            try respond(conn, status: 204, headers: [:], body: Data())
            return
        }

        if req.path != "/v1/info" && config.pinEnabled {
            let pinStatus = checkPin(req)
            guard pinStatus == 0 else {
                let code = pinStatus == 429 ? "too_many_requests" : "pin_required"
                let message = pinStatus == 429 ? "尝试次数过多，请稍后再试" : "需要配对码"
                try respondError(conn, pinStatus, code, message)
                return
            }
        }

        switch (req.method, req.path) {
        case ("GET", "/v1/info"):
            try respondJSON(conn, 200, infoPayload())

        case ("GET", "/v1/files"):
            let files = store.list().map { item -> [String: Any] in
                ["id": item.id, "name": item.name, "size": item.size,
                 "mime": item.mime, "mtime": Int(item.mtime.timeIntervalSince1970),
                 "kind": item.kind]
            }
            try respondJSON(conn, 200, ["files": files])

        case ("POST", "/v1/upload"):
            try handleUpload(req, conn)

        case ("POST", "/v1/text"):
            try handleText(req, conn)

        case ("POST", "/v1/cancel"):
            try handleCancel(req, conn)

        default:
            if req.path.hasPrefix("/v1/files/") && req.path.hasSuffix("/content") {
                let start = req.path.index(req.path.startIndex, offsetBy: "/v1/files/".count)
                let end = req.path.index(req.path.endIndex, offsetBy: -"/content".count)
                let id = String(req.path[start..<end])
                try handleDownload(req, conn, id: id)
            } else {
                try respondError(conn, 404, "not_found", "未知接口 \(req.path)")
            }
        }
    }

    // MARK: 配对码

    /// 0 = 通过；401 = 配对码错误；429 = 连续错误后被临时锁定
    private func checkPin(_ req: HTTPRequest) -> Int {
        pinLock.lock()
        defer { pinLock.unlock() }
        if let until = pinLockedUntil, until > Date() { return 429 }
        let provided = req.headers["x-pin"] ?? ""
        let expected = config.pin
        if constantTimeEquals(provided, expected) {
            pinFailures = 0
            return 0
        }
        pinFailures += 1
        if pinFailures >= 10 {
            pinLockedUntil = Date().addingTimeInterval(60)
            pinFailures = 0
        }
        return 401
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: 接口实现

    private func infoPayload() -> [String: Any] {
        [
            "app": "landrop", "v": 1,
            "id": config.deviceID,
            "name": config.name,
            "platform": "macos",
            "version": "1.0.0",
            "port": port,
            "pin_required": config.pinEnabled,
            "inbox": store.inbox.path,
            "free_bytes": store.freeSpace(),
            "host": Net.primaryIP(),
        ]
    }

    private func handleUpload(_ req: HTTPRequest, _ conn: Conn) throws {
        guard let rawName = req.headers["x-file-name"],
              let name = rawName.removingPercentEncoding, !name.isEmpty else {
            try respondError(conn, 400, "missing_name", "缺少 X-File-Name")
            return
        }
        guard let fileId = req.headers["x-file-id"], isValidFileId(fileId) else {
            try respondError(conn, 400, "missing_id", "缺少或无效的 X-File-Id")
            return
        }
        guard let total = Int64(req.headers["x-file-size"] ?? ""), total >= 0 else {
            try respondError(conn, 400, "missing_size", "缺少 X-File-Size")
            return
        }
        guard let offset = Int64(req.headers["x-offset"] ?? "0"), offset >= 0 else {
            try respondError(conn, 400, "bad_range", "X-Offset 无效")
            return
        }
        guard let length = Int(req.headers["content-length"] ?? ""), length >= 0 else {
            try respondError(conn, 400, "missing_length", "缺少 Content-Length")
            return
        }
        // 允许 0 字节文件；只有「声明非 0 总大小却发空 body」才拒绝
        if length == 0 && total != 0 {
            try respondError(conn, 400, "bad_range", "空请求体")
            return
        }
        if offset + Int64(length) > total {
            try respondError(conn, 400, "bad_range", "块长度超出总大小")
            return
        }

        registerInbound(fileId, conn)
        defer { unregisterInbound(fileId) }

        inboundLock.lock()
        let wasCancelled = cancelledUploads[fileId] != nil
        inboundLock.unlock()
        if wasCancelled {
            try respondError(conn, 410, "cancelled", "该传输已被取消")
            return
        }

        let (session, existing) = try store.beginUpload(fileId: fileId, rawName: name)
        if offset != existing {
            var payload: [String: Any] = ["error": ["code": "offset_mismatch",
                                                    "message": "偏移不一致"],
                                          "actual_offset": existing]
            if total > 0 { payload["size"] = total }
            try respondJSON(conn, 409, payload)
            return
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: session.partURL.path) {
            fm.createFile(atPath: session.partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: session.partURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written: Int64 = 0
        do {
            try conn.streamBody(length: length, into: handle) { n in
                written += Int64(n)
                let received = existing + written
                let name = session.finalName
                // 回调统一走主线程，避免后台线程直接改 AppModel 的 @Published 状态
                DispatchQueue.main.async { [weak self] in
                    self?.onUploadProgress?(fileId, name, received, total)
                }
            }
        } catch {
            self.onUploadAborted?(fileId)
            throw error
        }
        // 不在每个分片后 fsync：本机回环/局域网传输下会明显拖慢速度，
        // rename 本身是原子的，数据在页缓存里即可
        let received = existing + Int64(length)
        let complete = total == 0 || received >= total
        // 0 字节文件没有 streamBody 回调，仍给 UI 发一次完成进度
        if length == 0 {
            let name = session.finalName
            DispatchQueue.main.async { [weak self] in
                self?.onUploadProgress?(fileId, name, received, total)
            }
        }

        if complete {
            let item = try store.finishUpload(session)
            try respondJSON(conn, 200, [
                "id": item.id, "name": item.name, "size": item.size,
                "received": item.size, "complete": true,
            ])
        } else {
            try respondJSON(conn, 200, [
                "id": "", "name": session.finalName, "size": total,
                "received": received, "complete": false,
            ])
        }
    }

    /// 发送端主动取消：立刻关掉接收连接并通知 UI
    private func handleCancel(_ req: HTTPRequest, _ conn: Conn) throws {
        let length = Int(req.headers["content-length"] ?? "0") ?? 0
        let body = length > 0 ? (try? conn.readBody(length: length)) : Data()
        var fileId = req.headers["x-file-id"] ?? ""
        if fileId.isEmpty, let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            fileId = obj["file_id"] as? String ?? ""
        }
        NSLog("[LanDrop] /v1/cancel fileId=%@ known=%@", fileId, String(describing: inboundConns[fileId] != nil))
        if !fileId.isEmpty {
            cancelInbound(fileId: fileId)
            onUploadAborted?(fileId)
        }
        try respondJSON(conn, 200, ["cancelled": !fileId.isEmpty])
    }

    private func handleText(_ req: HTTPRequest, _ conn: Conn) throws {
        let length = Int(req.headers["content-length"] ?? "0") ?? 0
        guard length > 0 && length < 1024 * 1024 else {
            try respondError(conn, 400, "bad_text", "文本为空或过长（上限 1MB）")
            return
        }
        let body = try conn.readBody(length: length)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["text"] as? String else {
            try respondError(conn, 400, "bad_json", "请求体需要 {\"text\":\"...\"}")
            return
        }
        let item = store.saveText(text, name: obj["name"] as? String)
        try respondJSON(conn, 200, ["id": item.id, "name": item.name, "size": item.size])
    }

    private func handleDownload(_ req: HTTPRequest, _ conn: Conn, id: String) throws {
        guard let url = store.url(for: id) else {
            try respondError(conn, 404, "not_found", "文件不存在")
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            try respondError(conn, 500, "io", "无法打开文件")
            return
        }
        defer { try? handle.close() }

        let size = fileSize(url)
        let mime = store.mimeType(for: url)
        let encodedName = url.lastPathComponent.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "!*'();:@&=+$,/?#[]~ ").inverted
        ) ?? url.lastPathComponent

        var status = 200
        var start: Int64 = 0
        var end: Int64 = size - 1

        if let range = req.headers["range"], !range.isEmpty {
            if let parsed = parseRange(range, size: size) {
                start = parsed.start
                end = parsed.end
                status = 206
            } else {
                // 协议要求非法范围返回 416，而不是静默退回整文件 200
                try respond(conn, status: 416, headers: ["Content-Range": "bytes */\(size)"], body: Data())
                return
            }
        }

        let length = max(0, end - start + 1)
        var headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
            "ETag": "\"\(size)-\(fileMTime(url))\"",
            "Content-Disposition": "attachment; filename*=UTF-8''\(encodedName)",
        ]
        if status == 206 {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }

        let head = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
            + headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            + "\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        try conn.write(Data(head.utf8))

        if req.method == "HEAD" { return }

        try handle.seek(toOffset: UInt64(start))
        var remaining = length
        while remaining > 0 {
            let want = Int(min(262_144, remaining))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
            try conn.write(chunk)
            remaining -= Int64(chunk.count)
        }
    }

    // MARK: 取消接收

    private func registerInbound(_ fileId: String, _ conn: Conn) {
        inboundLock.lock(); inboundConns[fileId] = conn; inboundLock.unlock()
    }

    private func unregisterInbound(_ fileId: String) {
        inboundLock.lock(); inboundConns[fileId] = nil; inboundLock.unlock()
    }

    /// 关闭该次上传的 socket，让发送方收到连接中断
    func cancelInbound(fileId: String) {
        inboundLock.lock()
        let conn = inboundConns[fileId]
        cancelledUploads[fileId] = Date()
        // 清理 2 分钟前的记录，避免无限增长
        let cutoff = Date().addingTimeInterval(-120)
        cancelledUploads = cancelledUploads.filter { $0.value > cutoff }
        inboundLock.unlock()
        conn?.close()
    }

    // MARK: 应答

    private func respondJSON(_ conn: Conn, _ status: Int, _ obj: [String: Any]) throws {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
        try respond(conn, status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    private func respondError(_ conn: Conn, _ status: Int, _ code: String, _ message: String) throws {
        try respondJSON(conn, status, ["error": ["code": code, "message": message]])
    }

    private func respond(_ conn: Conn, status: Int, headers: [String: String], body: Data) throws {
        var all = headers
        all["Content-Length"] = "\(body.count)"
        all["Server"] = "LanDrop/1.0"
        let reason = Self.reason(status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += all.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        head += "\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type, X-File-Name, X-File-Id, X-File-Size, X-Offset, X-Pin\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, HEAD, OPTIONS\r\n\r\n"
        try conn.write(Data(head.utf8))
        if !body.isEmpty { try conn.write(body) }
    }

    /// X-File-Id 会参与分片文件名，必须挡住路径穿越字符
    private func isValidFileId(_ id: String) -> Bool {
        if id.isEmpty || id.count > 64 || id.hasPrefix(".") || id.contains("..") { return false }
        return id.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) ||   // 0-9
            (s.value >= 65 && s.value <= 90) ||   // A-Z
            (s.value >= 97 && s.value <= 122) ||  // a-z
            s.value == 46 || s.value == 95 || s.value == 45
        }
    }

    /// 解析 Range: bytes=...；非法返回 nil（由调用方回 416）
    private func parseRange(_ header: String, size: Int64) -> (start: Int64, end: Int64)? {
        guard header.hasPrefix("bytes="), !header.contains(","), size > 0 else { return nil }
        let spec = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard comps.count == 2 else { return nil }
        var start: Int64 = 0
        var end: Int64 = size - 1
        if comps[0].isEmpty {
            // bytes=-N：最后 N 字节
            guard let suffix = Int64(comps[1]), suffix > 0 else { return nil }
            start = max(0, size - suffix)
        } else {
            guard let s = Int64(comps[0]), s >= 0, s < size else { return nil }
            start = s
            if !comps[1].isEmpty {
                guard let e = Int64(comps[1]), e >= start else { return nil }
                end = min(e, size - 1)
            }
        }
        guard start <= end else { return nil }
        return (start, end)
    }

    private func fileSize(_ url: URL) -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let num = attrs[.size] as? NSNumber {
            return num.int64Value
        }
        return 0
    }

    private func fileMTime(_ url: URL) -> Int {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            return Int(date.timeIntervalSince1970)
        }
        return 0
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
