package com.landrop.android.nfc

import java.net.URI
import java.net.URLDecoder
import java.util.Locale

/** 贴纸默认端口（与 LAN 传输端口一致） */
const val DEFAULT_PORT = 47823

/**
 * NFC 贴纸里承载的设备信息。
 *
 * 只放"够用"的字段：目标是让整张贴纸（含 NDEF 头）能塞进 NTAG213 的 144 字节，
 * 名字太长时写入方会自动省略它，读到时再从 `/v1/info` 拿真名。
 */
data class TagTarget(
    val id: String,
    val name: String = "",
    val platform: String = "",
    val host: String,
    val port: Int = DEFAULT_PORT,
    val pinRequired: Boolean = false
)

/**
 * `landrop://tap?...` 贴纸载荷的编解码。纯 Kotlin，方便 JVM 单测。
 *
 * 格式（v1）：
 * ```
 * landrop://tap?v=1&id=<16 hex>&n=<名字>&p=<平台>&h=<host>&t=<port>[&k=1]
 * ```
 * - 所有值都是 percent-encoding 后的 UTF-8；`&`/`=`/中文都能安全往返
 * - `n`、`p` 可省；`k=1` 只在需要配对码时出现
 * - 只接受局域网地址（见 [isLanHost]），防止捡到一张恶意贴纸把文件传到公网
 *
 * macOS 端 `Sources/LanDrop/NFCTag.swift` 必须生成完全一致的字符串。
 */
object TagCodec {
    const val SCHEME = "landrop"
    const val HOST = "tap"
    const val VERSION = 1

    /** 解析上限：正常载荷 ~120 字节，超过这个长度直接当垃圾数据 */
    const val MAX_LENGTH = 512

    private val ID_PATTERN = Regex("^[0-9a-f]{8,32}$")

    fun buildUri(target: TagTarget, includeName: Boolean = true): String {
        val sb = StringBuilder(96)
        sb.append(SCHEME).append("://").append(HOST).append("?v=").append(VERSION)
        sb.append("&id=").append(target.id.lowercase(Locale.US))
        if (includeName && target.name.isNotBlank()) {
            sb.append("&n=").append(percentEncode(target.name.trim()))
        }
        if (target.platform.isNotBlank()) {
            sb.append("&p=").append(percentEncode(target.platform.trim().lowercase(Locale.US)))
        }
        sb.append("&h=").append(target.host.trim())
        sb.append("&t=").append(target.port)
        if (target.pinRequired) sb.append("&k=1")
        return sb.toString()
    }

    /** 解析失败一律返回 null：贴纸可能被随便写成了别的内容 */
    fun parseUri(raw: String?): TagTarget? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty() || text.length > MAX_LENGTH) return null
        val uri = runCatching { URI(text) }.getOrNull() ?: return null
        if (!SCHEME.equals(uri.scheme, ignoreCase = true)) return null
        if (uri.host?.lowercase(Locale.US) != HOST) return null

        val q = parseQuery(uri.rawQuery)
        if (q["v"]?.toIntOrNull() != VERSION) return null

        val id = q["id"]?.lowercase(Locale.US) ?: return null
        if (!ID_PATTERN.matches(id)) return null

        val host = q["h"]?.trim().orEmpty()
        if (!isLanHost(host)) return null

        val rawPort = q["t"]
        val port = if (rawPort == null) {
            DEFAULT_PORT
        } else {
            rawPort.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
        }
        val name = q["n"]?.let(::sanitizeName).orEmpty()
        val platform = q["p"]?.trim()?.lowercase(Locale.US)?.take(16).orEmpty()
        val pin = q["k"] == "1"

        return TagTarget(id = id, name = name, platform = platform, host = host, port = port, pinRequired = pin)
    }

    /**
     * 只放行"局域网里才可能出现"的地址：
     * IPv4 私有段 / 链路本地 / CGNAT，IPv6 链路本地与 ULA，以及 mDNS 的 `.local`。
     */
    fun isLanHost(host: String): Boolean {
        val h = host.trim()
        if (h.isEmpty() || h.length > 253) return false

        if (h.startsWith("[") && h.endsWith("]") && h.length > 2) {
            return isLanV6(h.substring(1, h.length - 1))
        }

        val parts = h.split('.')
        if (parts.size == 4) {
            val nums = parts.map { it.toIntOrNull() ?: return false }
            if (parts.any { it.isEmpty() || it.length > 3 || !it.all(Char::isDigit) }) return false
            if (nums.any { it !in 0..255 }) return false
            val (a, b) = nums[0] to nums[1]
            return a == 10 ||
                (a == 172 && b in 16..31) ||
                (a == 192 && b == 168) ||
                (a == 169 && b == 254) ||
                (a == 100 && b in 64..127)
        }

        val lower = h.lowercase(Locale.US)
        return lower.endsWith(".local") && lower.length > ".local".length
    }

    private fun isLanV6(raw: String): Boolean {
        val h = raw.substringBefore('%').lowercase(Locale.US)
        if (!h.contains(':')) return false
        return h.startsWith("fe8") || h.startsWith("fe9") ||
            h.startsWith("fea") || h.startsWith("feb") ||
            h.startsWith("fc") || h.startsWith("fd")
    }

    private fun sanitizeName(raw: String): String {
        val sb = StringBuilder(minOf(raw.length, 64))
        for (ch in raw.take(64)) {
            sb.append(if (ch.isISOControl()) ' ' else ch)
        }
        return sb.toString().trim()
    }

    private fun parseQuery(raw: String?): Map<String, String> {
        if (raw.isNullOrEmpty()) return emptyMap()
        val out = HashMap<String, String>(8)
        for (part in raw.split('&')) {
            if (part.isEmpty()) continue
            val eq = part.indexOf('=')
            val key = if (eq >= 0) part.substring(0, eq) else part
            val value = if (eq >= 0) part.substring(eq + 1) else ""
            out[key] = percentDecode(value) ?: continue
        }
        return out
    }

    /** RFC 3986 unreserved 之外全部 %XX；与 Swift 端 CharacterSet 白名单保持一致 */
    fun percentEncode(value: String): String {
        val sb = StringBuilder(value.length + 8)
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val c = byte.toInt() and 0xff
            if (c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code || c in '0'.code..'9'.code ||
                c == '-'.code || c == '.'.code || c == '_'.code || c == '~'.code
            ) {
                sb.append(c.toChar())
            } else {
                sb.append('%').append(HEX[c ushr 4]).append(HEX[c and 0x0f])
            }
        }
        return sb.toString()
    }

    fun percentDecode(value: String): String? =
        runCatching { URLDecoder.decode(value, "UTF-8") }.getOrNull()

    /**
     * 估算写进贴纸后的 NDEF 字节数（用于容量提示）：
     * URI 记录 5 字节头 + 载荷，TLV 2 字节；AAR 记录再多 37 字节。
     */
    fun ndefBytes(target: TagTarget, withAar: Boolean = true, includeName: Boolean = true): Int {
        val uriBytes = buildUri(target, includeName).toByteArray(Charsets.UTF_8).size
        var total = 5 + uriBytes + 2
        if (withAar) total += 37
        return total
    }

    private val HEX = "0123456789ABCDEF".toCharArray()
}
