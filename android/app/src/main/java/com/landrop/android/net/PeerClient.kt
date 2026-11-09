package com.landrop.android.net

import com.landrop.android.model.Peer
import com.landrop.android.model.RemoteFile
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import org.json.JSONObject

class UploadControl(val fileId: String) {
    @Volatile var pauseRequested: Boolean = false
    @Volatile var cancelRequested: Boolean = false
    @Volatile var offset: Long = 0L
}

enum class UploadOutcome { DONE, PAUSED, CANCELLED, FAILED, PIN_REQUIRED }

class PeerClient(private val pin: String? = null) {

    /** 最近一次请求是否因 401 被拒（供 UI 弹配对码框） */
    @Volatile var pinRequiredSeen: Boolean = false

    data class UploadResult(val ok: Boolean, val actualOffset: Long = -1, val message: String = "")

    private fun open(url: String, method: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 10_000
        conn.readTimeout = 120_000
        conn.useCaches = false
        conn.setRequestProperty("X-Pin", pin.orEmpty())
        return conn
    }

    private fun base(peer: Peer) = "http://${peer.host}:${peer.port}"

    fun info(peer: Peer): JSONObject? = runCatching {
        val conn = open("${base(peer)}/v1/info", "GET")
        try {
            if (conn.responseCode != 200) return null
            JSONObject(conn.inputStream.readBytes().toString(Charsets.UTF_8))
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    fun listFiles(peer: Peer): List<RemoteFile> = runCatching {
        val conn = open("${base(peer)}/v1/files", "GET")
        try {
            if (conn.responseCode != 200) return emptyList()
            val obj = JSONObject(conn.inputStream.readBytes().toString(Charsets.UTF_8))
            val arr = obj.optJSONArray("files") ?: return emptyList()
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                RemoteFile(o.optString("id"), o.optString("name"), o.optLong("size"), o.optString("kind"))
            }
        } finally {
            conn.disconnect()
        }
    }.getOrDefault(emptyList())

    /** 分块上传，支持 409 续传、暂停与取消 */
    fun upload(file: File, peer: Peer, control: UploadControl, displayName: String,
               onProgress: (Long, Long) -> Unit): UploadOutcome {
        val total = file.length()
        if (total < 0) return UploadOutcome.FAILED
        val fileId = control.fileId
        val name = URLEncoder.encode(displayName, "UTF-8").replace("+", "%20")
        val chunk = 4 * 1024 * 1024
        var offset = control.offset
        var retries = 0

        // 0 字节文件也要发一次空分片，否则对端永远收不到它
        if (total == 0L) {
            val conn = open("${base(peer)}/v1/upload", "POST")
            try {
                conn.doOutput = true
                conn.setRequestProperty("X-File-Name", name)
                conn.setRequestProperty("X-File-Id", fileId)
                conn.setRequestProperty("X-File-Size", "0")
                conn.setRequestProperty("X-Offset", "0")
                conn.setRequestProperty("Content-Type", "application/octet-stream")
                conn.setFixedLengthStreamingMode(0)
                conn.outputStream.use { }
                val code = conn.responseCode
                android.util.Log.i("LanDrop", "upload empty file code=$code")
                if (code == 200) {
                    control.offset = 0
                    onProgress(0, 0)
                    return UploadOutcome.DONE
                }
                if (code == 401) {
                    pinRequiredSeen = true
                    return UploadOutcome.PIN_REQUIRED
                }
                return UploadOutcome.FAILED
            } catch (e: Exception) {
                return if (control.cancelRequested) UploadOutcome.CANCELLED else UploadOutcome.FAILED
            } finally {
                conn.disconnect()
            }
        }

        RandomAccessFile(file, "r").use { raf ->
            while (offset < total) {
                if (control.cancelRequested) return UploadOutcome.CANCELLED
                if (control.pauseRequested) {
                    control.offset = offset
                    return UploadOutcome.PAUSED
                }
                val want = minOf(chunk.toLong(), total - offset).toInt()
                val data = ByteArray(want)
                raf.seek(offset)
                raf.readFully(data)

                val conn = open("${base(peer)}/v1/upload", "POST")
                try {
                    conn.doOutput = true
                    conn.setRequestProperty("X-File-Name", name)
                    conn.setRequestProperty("X-File-Id", fileId)
                    conn.setRequestProperty("X-File-Size", total.toString())
                    conn.setRequestProperty("X-Offset", offset.toString())
                    conn.setRequestProperty("Content-Type", "application/octet-stream")
                    conn.setFixedLengthStreamingMode(data.size)
                    conn.outputStream.use { out ->
                        // 分小块写，慢网下每 150ms 也能刷一次进度，不会长时间停在 0%
                        var written = 0
                        var lastEmit = 0L
                        while (written < data.size) {
                            if (control.cancelRequested) return UploadOutcome.CANCELLED
                            val n = minOf(64 * 1024, data.size - written)
                            out.write(data, written, n)
                            written += n
                            val now = System.currentTimeMillis()
                            if (now - lastEmit >= 150 || written == data.size) {
                                lastEmit = now
                                onProgress(offset + written, total)
                            }
                        }
                    }

                    val code = conn.responseCode
                    android.util.Log.i("LanDrop", "upload offset=$offset code=$code pinSet=${!pin.isNullOrEmpty()}")
                    if (code == 200) {
                        offset += data.size
                        control.offset = offset
                        retries = 0
                        onProgress(offset, total)
                    } else if (code == 409) {
                        val body = conn.errorStream?.readBytes()?.toString(Charsets.UTF_8).orEmpty()
                        val actual = runCatching { JSONObject(body).optLong("actual_offset", -1) }.getOrDefault(-1)
                        if (actual < 0) return UploadOutcome.FAILED
                        offset = actual
                        control.offset = actual
                        if (++retries > 8) return UploadOutcome.FAILED
                    } else {
                        if (code == 401) {
                            pinRequiredSeen = true
                            control.offset = offset
                            return UploadOutcome.PIN_REQUIRED
                        }
                        if (++retries > 6) return UploadOutcome.FAILED
                        Thread.sleep(700)
                    }
                } catch (e: Exception) {
                    // 对端关连接（取消/超时）时 responseCode 会抛 IOException，绝不能让它逃出协程
                    if (control.cancelRequested) return UploadOutcome.CANCELLED
                    if (++retries > 6) return UploadOutcome.FAILED
                    Thread.sleep(700)
                } finally {
                    conn.disconnect()
                }
            }
        }
        control.offset = total
        return UploadOutcome.DONE
    }

    /** Range 分块下载 */
    fun download(remote: RemoteFile, peer: Peer, target: File, onProgress: (Long, Long) -> Unit): Boolean {
        val chunk = 4 * 1024 * 1024L
        var offset = 0L
        target.parentFile?.mkdirs()
        RandomAccessFile(target, "rw").use { raf ->
            raf.setLength(0)
            while (offset < remote.size) {
                val end = minOf(offset + chunk - 1, remote.size - 1)
                val conn = open("${base(peer)}/v1/files/${remote.id}/content", "GET")
                try {
                    conn.setRequestProperty("Range", "bytes=$offset-$end")
                    val code = conn.responseCode
                    if (code == 401) pinRequiredSeen = true
                    if (code != 200 && code != 206) return false
                    val data = conn.inputStream.readBytes()
                    if (data.isEmpty()) break
                    raf.seek(offset)
                    raf.write(data)
                    offset += data.size
                    onProgress(offset, remote.size)
                } finally {
                    conn.disconnect()
                }
            }
        }
        // 空响应/提前断流不能让调用方误以为下载成功
        return offset == remote.size
    }

    /** 通知对端作废这次上传 */
    fun cancelUpload(peer: Peer, fileId: String) {
        runCatching {
            val conn = open("${base(peer)}/v1/cancel", "POST")
            try {
                conn.setRequestProperty("X-File-Id", fileId)
                conn.setFixedLengthStreamingMode(0)
                conn.outputStream.use { }
                val code = conn.responseCode
                android.util.Log.i("LanDrop", "cancelUpload fileId=$fileId -> $code")
            } finally {
                conn.disconnect()
            }
        }
    }

    fun sendText(peer: Peer, text: String, name: String?): Boolean = runCatching {
        val conn = open("${base(peer)}/v1/text", "POST")
        try {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("text", text).apply {
                if (!name.isNullOrEmpty()) put("name", name)
            }.toString().toByteArray()
            conn.setFixedLengthStreamingMode(body.size)
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            if (code == 401) pinRequiredSeen = true
            code == 200
        } finally {
            conn.disconnect()
        }
    }.getOrDefault(false)
}
