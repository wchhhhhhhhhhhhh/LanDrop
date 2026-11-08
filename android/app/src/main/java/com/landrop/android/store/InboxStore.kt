package com.landrop.android.store

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.landrop.android.model.FileItem
import com.landrop.android.model.stableId
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors

/**
 * 收件箱：外部私有目录 LanDrop/inbox，上传中的分片放 filesDir/partials。
 * 有 FileProvider 暴露，可用系统「打开/分享」读走。
 */
class InboxStore(context: Context) {

    private val ctx: Context = context.applicationContext

    val inbox: File = File(context.getExternalFilesDir(null) ?: context.filesDir, "LanDrop/inbox").apply { mkdirs() }
    // 分片放内部存储（比模拟外部存储快得多）；完成时若跨卷 rename 失败则 copy
    private val partials: File = File(context.filesDir, "partials").apply { mkdirs() }
    // 复制到系统「下载」很慢，放到单线程后台做，避免拖慢最后一块的 HTTP 响应
    private val publishExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "landrop-publish").apply { isDaemon = true }
    }

    fun findPublished(name: String): Uri? {
        if (Build.VERSION.SDK_INT < 29) {
            return null
        }
        return try {
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val cursor = ctx.contentResolver.query(
                collection,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH} LIKE ?",
                arrayOf(name, "%LanDrop%"),
                null
            ) ?: return null
            cursor.use {
                if (it.moveToFirst()) {
                    Uri.withAppendedPath(collection, it.getLong(0).toString())
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    fun list(): List<FileItem> {
        val items = ArrayList<FileItem>()
        inbox.listFiles()?.forEach { f ->
            if (!f.isFile || f.name.startsWith(".")) return@forEach
            items.add(
                FileItem(
                    id = stableId(f.name),
                    name = f.name,
                    size = f.length(),
                    mtime = f.lastModified(),
                    kind = if (f.name.endsWith(".txt")) "text" else "file",
                    file = f,
                    uri = findPublished(f.name)
                )
            )
        }
        return items.sortedByDescending { it.mtime }
    }

    fun find(id: String): FileItem? = list().firstOrNull { it.id == id }

    fun partFile(fileId: String): File {
        // fileId 来自请求头，不能直接拼进路径：清理并附加稳定哈希防碰撞
        val safe = fileId.map { if (it.isLetterOrDigit() && it.code < 128 || it == '_' || it == '-') it else '_' }
            .joinToString("").take(64)
        val prefix = safe.ifEmpty { "upload" }
        return File(partials, "$prefix-${stableId(fileId)}.part")
    }

    fun partSize(fileId: String): Long = partFile(fileId).let { if (it.exists()) it.length() else 0L }

    fun append(fileId: String, offset: Long, data: ByteArray): Long {
        val part = partFile(fileId)
        RandomAccessFile(part, "rw").use { raf ->
            raf.seek(offset)
            raf.write(data)
        }
        return part.length()
    }

    /** 复制一份到系统「下载/LanDrop」，并返回 MediaStore URI（文件管理器可见、可被系统应用打开） */
    fun publishToDownloads(file: File): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null
        return runCatching {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(file.name))
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/LanDrop")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = ctx.contentResolver.insert(collection, values) ?: return null
            ctx.contentResolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { ins -> ins.copyTo(out, 256 * 1024) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            ctx.contentResolver.update(uri, values, null, null)
            uri
        }.getOrNull()
    }

    fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    fun finish(fileId: String, rawName: String): FileItem {
        val part = partFile(fileId)
        var finalName = uniqueName(sanitize(rawName))
        var target = File(inbox, finalName)
        // 极小概率的并发重名：再取一次唯一名，绝不删除已有文件
        if (target.exists()) {
            finalName = uniqueName(finalName)
            target = File(inbox, finalName)
        }
        if (!part.renameTo(target)) {
            part.copyTo(target, overwrite = true)
            part.delete()
        }
        val item = FileItem(
            id = stableId(finalName),
            name = finalName,
            size = target.length(),
            mtime = target.lastModified(),
            kind = if (finalName.endsWith(".txt")) "text" else "file",
            file = target,
            uri = null
        )
        publishExecutor.execute { publishToDownloads(target) }
        return item
    }

    fun saveText(text: String, name: String?): FileItem {
        var base = if (name.isNullOrBlank()) "文本-${timestamp()}.txt" else sanitize(name)
        if (!base.endsWith(".txt")) base += ".txt"
        val finalName = uniqueName(base)
        val target = File(inbox, finalName)
        target.writeText(text)
        val item = FileItem(
            id = stableId(finalName),
            name = finalName,
            size = target.length(),
            mtime = target.lastModified(),
            kind = "text",
            file = target,
            uri = null
        )
        publishExecutor.execute { publishToDownloads(target) }
        return item
    }

    fun delete(item: FileItem) {
        runCatching { item.file.delete() }
    }

    fun sanitize(raw: String): String {
        // 调用方（HttpServer）已经按协议解码过一次，这里只做安全清理
        var s = raw
        s = s.replace("/", "_").replace("\\", "_").replace(":", "_")
            .replace("..", "_")
            .replace(Regex("[\\u0000-\\u001f]"), "")
            .trim()
        if (s.isEmpty()) s = "未命名-${timestamp()}"
        if (s.length > 120) s = s.substring(0, 120)
        return s
    }

    fun uniqueName(name: String): String {
        val f = File(inbox, name)
        if (!f.exists()) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 1..9999) {
            val candidate = "$base ($i)$ext"
            if (!File(inbox, candidate).exists()) return candidate
        }
        return "$base-${System.currentTimeMillis()}$ext"
    }

    fun uniqueNameIn(dir: File, name: String): String {
        if (!File(dir, name).exists()) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (i in 1..9999) {
            val candidate = "$base ($i)$ext"
            if (!File(dir, candidate).exists()) return candidate
        }
        return "$base-${System.currentTimeMillis()}$ext"
    }

    private fun timestamp(): String {
        val sdf = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US)
        return sdf.format(java.util.Date())
    }
}
