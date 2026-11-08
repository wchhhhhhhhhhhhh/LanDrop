package com.landrop.android.model

import java.io.File

enum class Platform(val label: String) {
    MACOS("macOS"), ANDROID("Android"), HARMONY("HarmonyOS"), UNKNOWN("未知");

    companion object {
        fun from(raw: String?): Platform = when (raw?.lowercase()) {
            "macos", "mac", "osx" -> MACOS
            "android" -> ANDROID
            "harmony", "harmonyos", "ohos" -> HARMONY
            else -> UNKNOWN
        }
    }
}

data class Peer(
    val id: String,
    val name: String,
    val platform: Platform,
    val host: String,
    val port: Int,
    val pinRequired: Boolean,
    val lastSeen: Long = System.currentTimeMillis()
) {
    val online: Boolean get() = System.currentTimeMillis() - lastSeen < 30_000
    val endpoint: String get() = "$host:$port"
}

data class FileItem(
    val id: String,
    val name: String,
    val size: Long,
    val mtime: Long,
    val kind: String,
    val file: File,
    val uri: android.net.Uri? = null
) {
    val sizeText: String get() = formatSize(size)
}

data class RemoteFile(val id: String, val name: String, val size: Long, val kind: String)

data class Transfer(
    val id: String = java.util.UUID.randomUUID().toString(),
    val fileName: String,
    val peerName: String,
    val direction: String, // send | receive
    var total: Long,
    var sent: Long = 0,
    var state: String = "running", // running | done | failed
    var error: String? = null,
    var speed: Long = 0,           // 字节/秒（滑动平均）
    val startedAt: Long = System.currentTimeMillis()
) {
    val progress: Float get() = if (total <= 0) 0f else (sent.toFloat() / total).coerceIn(0f, 1f)

    val speedText: String get() = if (speed > 0) formatSize(speed) + "/s" else "—"
}

fun formatSize(bytes: Long): String {
    if (bytes < 1000) return "$bytes B"
    val units = listOf("KB", "MB", "GB", "TB")
    var v = bytes / 1000.0
    var i = 0
    while (v >= 1000 && i < units.size - 1) { v /= 1000; i++ }
    return String.format(if (v >= 10) "%.0f %s" else "%.1f %s", v, units[i])
}

fun stableId(name: String): String {
    var hash = -2128831035
    for (c in name) {
        hash = hash xor c.code
        hash *= 16777619
    }
    return Integer.toHexString(hash) + Integer.toHexString(name.length)
}
