import Foundation

enum PeerError: LocalizedError {
    case http(Int)
    case pin
    case badURL
    case aborted
    case incomplete

    var errorDescription: String? {
        switch self {
        case .http(let code): return "对方返回 HTTP \(code)"
        case .pin: return "配对码错误"
        case .badURL: return "地址无效"
        case .aborted: return "已取消"
        case .incomplete: return "连接中断，文件不完整"
        }
    }
}

enum UploadOutcome {
    case done, paused, cancelled, failed, pinRequired
}

/// 上传控制句柄
final class UploadControl {
    let fileId: String
    var pauseRequested = false
    var cancelRequested = false
    var offset: Int64 = 0

    init(fileId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) {
        self.fileId = fileId
    }
}

/// 上传过程中按 URLSession 实际写出的字节数回调，避免 4 MiB 分块之间长时间没有进度
private final class UploadProgressSink: NSObject, URLSessionTaskDelegate {
    var onSend: ((Int64) -> Void)?
    private var lastEmit = Date.distantPast
    private let lock = NSLock()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.lock()
        let now = Date()
        let emit = now.timeIntervalSince(lastEmit) >= 0.08
        if emit { lastEmit = now }
        let callback = emit ? onSend : nil
        lock.unlock()
        callback?(totalBytesSent)
    }
}

/// 对端 HTTP 客户端：上传（分块续传）/ 下载（Range 分块）/ 文本
struct PeerClient {
    var pin: String?
    var session: URLSession = .shared

    /// 4 MiB：断点续传粒度和进度刷新的折中（README 一直写的就是 4 MiB）
    private let chunkSize = 4 * 1024 * 1024

    private func makeRequest(_ url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let pin, !pin.isEmpty { req.setValue(pin, forHTTPHeaderField: "X-Pin") }
        req.httpBody = body
        return req
    }

    // MARK: 探测

    func info(_ peer: Peer) async throws -> [String: Any] {
        let req = makeRequest(peer.baseURL.appendingPathComponent("v1/info"), method: "GET")
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func listFiles(_ peer: Peer) async throws -> [RemoteFile] {
        let req = makeRequest(peer.baseURL.appendingPathComponent("v1/files"), method: "GET")
        let (data, resp) = try await session.data(for: req)
        try validate(resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["files"] as? [[String: Any]] else { return [] }
        return arr.compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return RemoteFile(
                id: id,
                name: name,
                size: (f["size"] as? NSNumber)?.int64Value ?? 0,
                mime: f["mime"] as? String ?? "application/octet-stream",
                kind: f["kind"] as? String ?? "file"
            )
        }
    }

    // MARK: 上传

    func upload(file: URL,
                to peer: Peer,
                control: UploadControl,
                progress: @escaping (Int64, Int64) -> Void) async -> UploadOutcome {
        do {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let total = (attrs[.size] as? NSNumber)?.int64Value, total >= 0 else {
            return .failed
        }
        let fileId = control.fileId
        let encodedName = file.lastPathComponent.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics
        ) ?? "file"

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        // 0 字节文件也要发一次空分片，否则对端永远收不到它
        if total == 0 {
            let headers: [String: String] = [
                "X-File-Name": encodedName,
                "X-File-Id": fileId,
                "X-File-Size": "0",
                "X-Offset": "0",
                "Content-Length": "0",
            ]
            let req = makeRequest(peer.baseURL.appendingPathComponent("v1/upload"),
                                  method: "POST", headers: headers, body: Data())
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                control.offset = 0
                progress(0, 0)
                return .done
            }
            _ = data
            return code == 401 ? .pinRequired : .failed
        }

        var offset: Int64 = control.offset
        var retries = 0

        // 整个上传只建一个带 delegate 的 session，逐块复用它
        let sink = UploadProgressSink()
        let progressSession = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
        defer { progressSession.finishTasksAndInvalidate() }

        while offset < total {
            if control.cancelRequested { return .cancelled }
            if control.pauseRequested {
                control.offset = offset
                return .paused
            }
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }

            let headers: [String: String] = [
                "X-File-Name": encodedName,
                "X-File-Id": fileId,
                "X-File-Size": "\(total)",
                "X-Offset": "\(offset)",
                "Content-Type": "application/octet-stream",
            ]
            let req = makeRequest(peer.baseURL.appendingPathComponent("v1/upload"),
                                  method: "POST", headers: headers)
            sink.onSend = { sent in progress(offset + sent, total) }
            do {
                let (data, resp) = try await progressSession.upload(for: req, from: chunk)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 409,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let actual = (obj["actual_offset"] as? NSNumber)?.int64Value {
                    retries += 1
                    if retries > 8 { return .failed }
                    offset = actual
                    control.offset = actual
                    progress(offset, total)
                    continue
                }
                guard code == 200 else { throw code == 401 ? PeerError.pin : PeerError.http(code) }
                offset += Int64(chunk.count)
                control.offset = offset
                retries = 0
                progress(offset, total)
            } catch let err as PeerError {
                throw err
            } catch {
                retries += 1
                if retries > 6 { return .failed }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        control.offset = total
        return .done
        } catch {
            if let e = error as? PeerError, case .pin = e { return .pinRequired }
            return .failed
        }
    }

    // MARK: 下载

    func download(_ file: RemoteFile,
                  from peer: Peer,
                  to directory: URL,
                  progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        let dest = Self.uniqueURL(in: directory, name: file.name)
        fm.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var offset: Int64 = 0
        while offset < file.size {
            let end = min(offset + Int64(chunkSize) - 1, file.size - 1)
            var req = makeRequest(peer.baseURL.appendingPathComponent("v1/files/\(file.id)/content"), method: "GET")
            req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 206 else {
                throw code == 401 ? PeerError.pin : PeerError.http(code)
            }
            guard !data.isEmpty else { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset, file.size)
        }
        try handle.synchronize()
        guard offset == file.size else {
            try? handle.close()
            try? FileManager.default.removeItem(at: dest)
            throw PeerError.incomplete
        }
        return dest
    }

    /// 通知对端「这次上传作废」
    func cancelUpload(peer: Peer, fileId: String) async throws {
        var req = makeRequest(peer.baseURL.appendingPathComponent("v1/cancel"), method: "POST")
        req.setValue(fileId, forHTTPHeaderField: "X-File-Id")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        _ = try await session.data(for: req)
    }

    // MARK: 文本

    func sendText(_ text: String, name: String?, to peer: Peer) async throws {
        let payload: [String: Any] = name.map { ["text": text, "name": $0] } ?? ["text": text]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = makeRequest(peer.baseURL.appendingPathComponent("v1/text"),
                              method: "POST",
                              headers: ["Content-Type": "application/json"],
                              body: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            _ = data
            throw code == 401 ? PeerError.pin : PeerError.http(code)
        }
    }

    // MARK: 工具

    private func validate(_ resp: URLResponse) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw code == 401 ? PeerError.pin : PeerError.http(code)
        }
    }

    /// 远端文件名不可信：去掉路径分隔符、..、控制字符，避免写到收件箱之外
    static func sanitizeName(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        s = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "未命名-\(Int(Date().timeIntervalSince1970))" }
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

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let safe = sanitizeName(name)
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(safe)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = safe as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var i = 1
        while true {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
