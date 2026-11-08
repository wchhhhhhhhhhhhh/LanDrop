package com.landrop.android.net

import com.landrop.android.model.FileItem
import com.landrop.android.store.InboxStore
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

class HttpServer(
    private val store: InboxStore,
    private val identity: () -> Identity,
    private val onReceive: (FileItem) -> Unit
) {
    data class Identity(val id: String, val name: String, val pin: String, val pinRequired: Boolean)

    private var serverSocket: ServerSocket? = null
    @Volatile private var running = false
    private val inboundSockets = java.util.concurrent.ConcurrentHashMap<String, Socket>()
    private val pinFailures = AtomicInteger(0)
    @Volatile private var lockedUntil = 0L

    var port: Int = 47823
        private set

    /** 接收进度回调：(fileId, name, 已收字节, 总字节, 来源IP) */
    var onUploadProgress: ((String, String, Long, Long, String) -> Unit)? = null

    /** 接收中断（对端取消/断网） */
    var onUploadAborted: ((String) -> Unit)? = null

    val isRunning: Boolean get() = running

    fun start(preferred: Int): Int? {
        var bound: ServerSocket? = null
        var p = preferred
        for (i in 0 until 10) {
            try {
                val s = ServerSocket()
                s.reuseAddress = true
                s.bind(InetSocketAddress(p), 64)
                bound = s
                port = p
                break
            } catch (e: Exception) {
                p++
            }
        }
        val server = bound ?: return null
        serverSocket = server
        running = true
        Thread({ acceptLoop(server) }, "landrop-http").apply { isDaemon = true }.start()
        return port
    }

    /** 本地取消某次接收：关掉对应 socket */
    fun cancelInbound(fileId: String) {
        inboundSockets.remove(fileId)?.let { runCatching { it.close() } }
    }

    fun stop() {
        running = false
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running) {
            val socket = try {
                server.accept()
            } catch (e: Exception) {
                if (!running) break
                continue
            }
            Thread({ runCatching { handle(socket) } }, "landrop-conn").apply { isDaemon = true }.start()
        }
    }

    private data class Request(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val contentLength: Int
    )

    private fun handle(socket: Socket) {
        socket.use { s ->
            s.soTimeout = 120_000
            val input = BufferedInputStream(s.getInputStream())
            val out = BufferedOutputStream(s.getOutputStream())
            val head = readHead(input) ?: return
            val req = parseHead(head) ?: return

            if (req.method == "OPTIONS") {
                out.write(responseHead(204, emptyMap(), 0))
                out.flush()
                return
            }

            val me = identity()
            if (req.path != "/v1/info" && me.pinRequired) {
                if (!checkPin(req, me.pin)) {
                    val body = errorJson("pin_required", "需要配对码").toByteArray()
                    out.write(responseHead(if (System.currentTimeMillis() < lockedUntil) 429 else 401,
                        mapOf("Content-Type" to "application/json; charset=utf-8"), body.size.toLong()))
                    out.write(body)
                    out.flush()
                    return
                }
            }

            if (req.headers["expect"]?.equals("100-continue", ignoreCase = true) == true) {
                out.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray())
                out.flush()
            }

            when {
                req.method == "GET" && req.path == "/v1/info" -> {
                    val json = JSONObject()
                        .put("app", "landrop")
                        .put("v", 1)
                        .put("id", me.id)
                        .put("name", me.name)
                        .put("platform", "android")
                        .put("version", "1.0.0")
                        .put("port", port)
                        .put("pin_required", me.pinRequired)
                        .put("inbox", store.inbox.absolutePath)
                        .put("host", NetInfo.localIp())
                    writeJson(out, 200, json.toString())
                }

                req.method == "GET" && req.path == "/v1/files" -> {
                    val arr = org.json.JSONArray()
                    store.list().forEach { it ->
                        arr.put(JSONObject()
                            .put("id", it.id)
                            .put("name", it.name)
                            .put("size", it.size)
                            .put("mime", if (it.kind == "text") "text/plain" else "application/octet-stream")
                            .put("mtime", it.mtime / 1000)
                            .put("kind", it.kind))
                    }
                    writeJson(out, 200, JSONObject().put("files", arr).toString())
                }

                req.method == "POST" && req.path == "/v1/upload" ->
                    handleUpload(req, input, out, s.inetAddress.hostAddress ?: "远端设备", s)

                req.method == "POST" && req.path == "/v1/cancel" -> {
                    val fid = req.headers["x-file-id"] ?: ""
                    if (fid.isNotEmpty()) {
                        inboundSockets.remove(fid)?.let { runCatching { it.close() } }
                        onUploadAborted?.invoke(fid)
                    }
                    writeJson(out, 200, JSONObject().put("cancelled", fid.isNotEmpty()).toString())
                }

                req.method == "POST" && req.path == "/v1/text" -> handleText(req, input, out)

                req.path.startsWith("/v1/files/") && req.path.endsWith("/content") -> {
                    val id = req.path.removePrefix("/v1/files/").removeSuffix("/content")
                    handleDownload(req, id, out)
                }

                else -> writeJson(out, 404, errorJson("not_found", "未知接口"))
            }
        }
    }

    // MARK: - 路由实现

    private fun handleUpload(req: Request, input: InputStream, out: OutputStream, fromIp: String, socket: Socket) {
        val rawName = req.headers["x-file-name"]
        val fileId = req.headers["x-file-id"] ?: ""
        val hasSize = req.headers.containsKey("x-file-size")
        val total = req.headers["x-file-size"]?.toLongOrNull() ?: -1L
        val offset = req.headers["x-offset"]?.toLongOrNull() ?: 0L

        if (rawName.isNullOrEmpty() || !isValidFileId(fileId) || fileId.isEmpty() || !hasSize ||
            total < 0 || offset < 0 || req.contentLength < 0) {
            writeJson(out, 400, errorJson("bad_upload", "缺少或无效的 X-File-Name / X-File-Id / X-File-Size"))
            return
        }
        // 允许 0 字节文件；只有「声明非 0 总大小却发空 body」才拒绝
        if (req.contentLength == 0 && total != 0L) {
            writeJson(out, 400, errorJson("bad_upload", "空请求体"))
            return
        }
        if (offset + req.contentLength > total) {
            writeJson(out, 400, errorJson("bad_range", "块长度超出总大小"))
            return
        }
        // URLDecoder 会把 '+' 当空格；协议里 '+' 是普通字符，先转义再解码
        val name = runCatching { URLDecoder.decode(rawName.replace("+", "%2B"), "UTF-8") }
            .getOrDefault(rawName)

        val existing = store.partSize(fileId)
        if (offset != existing) {
            val body = JSONObject()
                .put("error", JSONObject().put("code", "offset_mismatch").put("message", "偏移不一致"))
                .put("actual_offset", existing)
                .toString()
            writeJson(out, 409, body)
            return
        }

        inboundSockets[fileId] = socket
        var remaining = req.contentLength
        var written = 0
        var lastReport = 0
        try {
        val buffer = ByteArray(256 * 1024)
        RandomAccessFile(store.partFile(fileId), "rw").use { raf ->
            raf.seek(offset)
            while (remaining > 0) {
                val want = minOf(buffer.size, remaining)
                val read = input.read(buffer, 0, want)
                if (read <= 0) break
                raf.write(buffer, 0, read)
                remaining -= read
                written += read
                if (written - lastReport >= 256 * 1024 || remaining == 0) {
                    lastReport = written
                    onUploadProgress?.invoke(fileId, name, existing + written, total, fromIp)
                }
            }
        }

        } finally {
            inboundSockets.remove(fileId)
        }
        if (remaining > 0) {
            onUploadAborted?.invoke(fileId)
            return
        }
        val received = existing + (req.contentLength - remaining)
        val complete = total == 0L || received >= total
        // 0 字节文件没有循环内的进度回调，仍给 UI 发一次完成进度
        if (req.contentLength == 0) {
            onUploadProgress?.invoke(fileId, name, received, total, fromIp)
        }
        if (complete) {
            val item = store.finish(fileId, name)
            onReceive(item)
            writeJson(out, 200, JSONObject()
                .put("id", item.id).put("name", item.name)
                .put("size", item.size).put("received", item.size)
                .put("complete", true).toString())
        } else {
            writeJson(out, 200, JSONObject()
                .put("id", "").put("name", name)
                .put("size", total).put("received", received)
                .put("complete", false).toString())
        }
    }

    private fun handleText(req: Request, input: InputStream, out: OutputStream) {
        if (req.contentLength <= 0 || req.contentLength > 1024 * 1024) {
            writeJson(out, 400, errorJson("bad_text", "文本为空或过长"))
            return
        }
        val body = readN(input, req.contentLength)
        val obj = runCatching { JSONObject(String(body, Charsets.UTF_8)) }.getOrNull()
        val text = obj?.optString("text").orEmpty()
        if (text.isEmpty()) {
            writeJson(out, 400, errorJson("bad_json", "请求体需要 {\"text\":\"...\"}"))
            return
        }
        val item = store.saveText(text, obj?.optString("name"))
        onReceive(item)
        writeJson(out, 200, JSONObject()
            .put("id", item.id).put("name", item.name).put("size", item.size).toString())
    }

    private fun handleDownload(req: Request, id: String, out: OutputStream) {
        val item = store.find(id)
        if (item == null) {
            writeJson(out, 404, errorJson("not_found", "文件不存在"))
            return
        }
        val size = item.size
        var start = 0L
        var end = size - 1
        var status = 200

        val range = req.headers["range"]
        if (!range.isNullOrEmpty()) {
            val parsed = parseRange(range, size)
            if (parsed == null) {
                // 协议要求非法范围返回 416，而不是静默退回整文件 200
                out.write(responseHead(416, mapOf("Content-Range" to "bytes */$size"), 0))
                out.flush()
                return
            }
            start = parsed.first
            end = parsed.second
            status = 206
        }

        val length = maxOf(0L, end - start + 1)
        val encoded = java.net.URLEncoder.encode(item.name, "UTF-8").replace("+", "%20")
        val headers = mutableMapOf(
            "Content-Type" to "application/octet-stream",
            "Accept-Ranges" to "bytes",
            "Content-Disposition" to "attachment; filename*=UTF-8''$encoded"
        )
        if (status == 206) headers["Content-Range"] = "bytes $start-$end/$size"
        out.write(responseHead(status, headers, length))
        if (req.method == "HEAD") {
            out.flush(); return
        }
        File(item.file.absolutePath).inputStream().use { fileIn ->
            var skip = start
            while (skip > 0) {
                val skipped = fileIn.skip(skip)
                if (skipped <= 0) break
                skip -= skipped
            }
            var remaining = length
            val buffer = ByteArray(64 * 1024)
            while (remaining > 0) {
                val want = minOf(buffer.size.toLong(), remaining).toInt()
                val read = fileIn.read(buffer, 0, want)
                if (read <= 0) break
                out.write(buffer, 0, read)
                remaining -= read
            }
        }
        out.flush()
    }

    // MARK: - 协议工具

    /** X-File-Id 会参与分片文件名，必须挡住路径穿越字符 */
    private fun isValidFileId(id: String?): Boolean {
        if (id.isNullOrEmpty() || id.length > 64 || id.startsWith(".") || id.contains("..")) return false
        return id.all { ch ->
            (ch.isLetterOrDigit() && ch.code < 128) || ch == '_' || ch == '-' || ch == '.'
        }
    }

    /** 解析 Range: bytes=...；非法返回 null（由调用方回 416） */
    private fun parseRange(header: String, size: Long): Pair<Long, Long>? {
        if (!header.startsWith("bytes=") || header.contains(",") || size <= 0) return null
        val spec = header.removePrefix("bytes=").trim()
        val parts = spec.split("-", limit = 2)
        if (parts.size != 2) return null
        var start = 0L
        var end = size - 1
        if (parts[0].isEmpty()) {
            val suffix = parts[1].toLongOrNull() ?: return null
            if (suffix <= 0) return null
            start = maxOf(0L, size - suffix)
        } else {
            start = parts[0].toLongOrNull() ?: return null
            if (start < 0 || start >= size) return null
            if (parts[1].isNotEmpty()) {
                val e = parts[1].toLongOrNull() ?: return null
                if (e < start) return null
                end = minOf(e, size - 1)
            }
        }
        if (start > end) return null
        return start to end
    }

    private fun checkPin(req: Request, expected: String): Boolean {
        if (System.currentTimeMillis() < lockedUntil) return false
        val provided = req.headers["x-pin"] ?: ""
        val ok = provided.length == expected.length &&
            provided.zip(expected).fold(0) { acc, (a, b) -> acc or (a.code xor b.code) } == 0
        if (ok) {
            pinFailures.set(0)
            return true
        }
        if (pinFailures.incrementAndGet() >= 10) {
            lockedUntil = System.currentTimeMillis() + 60_000
            pinFailures.set(0)
        }
        return false
    }

    private fun readHead(input: InputStream): String? {
        val buf = java.io.ByteArrayOutputStream()
        var state = 0
        while (true) {
            val b = input.read()
            if (b < 0) return null
            buf.write(b)
            state = when {
                b == 13 -> if (state % 2 == 0) state + 1 else 0
                b == 10 -> if (state % 2 == 1) state + 1 else 0
                else -> 0
            }
            if (state == 4) break
            if (buf.size() > 64 * 1024) return null
        }
        return buf.toString("UTF-8")
    }

    private fun parseHead(head: String): Request? {
        val lines = head.split("\r\n")
        val first = lines.firstOrNull()?.split(" ") ?: return null
        if (first.size < 2) return null
        val headers = HashMap<String, String>()
        for (i in 1 until lines.size) {
            val idx = lines[i].indexOf(':')
            if (idx <= 0) continue
            headers[lines[i].substring(0, idx).trim().lowercase()] =
                lines[i].substring(idx + 1).trim()
        }
        return Request(
            method = first[0].uppercase(),
            path = first[1].substringBefore('?'),
            headers = headers,
            contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        )
    }

    private fun readN(input: InputStream, n: Int): ByteArray {
        val out = ByteArray(n)
        var read = 0
        while (read < n) {
            val r = input.read(out, read, n - read)
            if (r <= 0) break
            read += r
        }
        return if (read == n) out else out.copyOf(read)
    }

    private fun responseHead(status: Int, headers: Map<String, String>, length: Long): ByteArray {
        val sb = StringBuilder()
        sb.append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
        headers.forEach { (k, v) -> sb.append(k).append(": ").append(v).append("\r\n") }
        if (!headers.containsKey("Content-Type")) {
            sb.append("Content-Type: application/octet-stream\r\n")
        }
        sb.append("Content-Length: ").append(length).append("\r\n")
        sb.append("Connection: close\r\n")
        sb.append("Access-Control-Allow-Origin: *\r\n")
        sb.append("Access-Control-Allow-Headers: Content-Type, X-File-Name, X-File-Id, X-File-Size, X-Offset, X-Pin\r\n")
        sb.append("\r\n")
        return sb.toString().toByteArray()
    }

    private fun writeJson(out: OutputStream, status: Int, body: String) {
        val bytes = body.toByteArray()
        out.write(responseHead(status, mapOf("Content-Type" to "application/json; charset=utf-8"), bytes.size.toLong()))
        out.write(bytes)
        out.flush()
    }

    private fun errorJson(code: String, message: String) =
        JSONObject().put("error", JSONObject().put("code", code).put("message", message)).toString()

    private fun reason(status: Int) = when (status) {
        200 -> "OK"
        204 -> "No Content"
        206 -> "Partial Content"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        404 -> "Not Found"
        409 -> "Conflict"
        410 -> "Gone"
        416 -> "Range Not Satisfiable"
        429 -> "Too Many Requests"
        else -> "Status"
    }

    companion object {
        const val TCP_PORT = 47823
        const val UDP_PORT = 47824
    }
}
