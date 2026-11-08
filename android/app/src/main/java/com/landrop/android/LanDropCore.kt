package com.landrop.android

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import com.landrop.android.model.FileItem
import com.landrop.android.model.Peer
import com.landrop.android.model.Platform
import com.landrop.android.model.Transfer
import com.landrop.android.net.Discovery
import com.landrop.android.net.HttpServer
import com.landrop.android.net.NetInfo
import com.landrop.android.net.PeerClient
import com.landrop.android.net.UploadControl
import com.landrop.android.net.UploadOutcome
import com.landrop.android.store.InboxStore
import java.io.File
import java.util.UUID
import org.json.JSONObject

/** 全局状态与业务编排 */
object LanDropCore {

    private lateinit var context: Context
    private lateinit var prefs: android.content.SharedPreferences
    private val crashGuard = kotlinx.coroutines.CoroutineExceptionHandler { _, e ->
        android.util.Log.e("LanDrop", "后台任务异常: ${e.message}", e)
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + crashGuard)

    lateinit var store: InboxStore
        private set

    private var server: HttpServer? = null
    private var discovery: Discovery? = null

    val peers = MutableStateFlow<List<Peer>>(emptyList())
    val files = MutableStateFlow<List<FileItem>>(emptyList())
    val transfers = MutableStateFlow<List<Transfer>>(emptyList())
    val running = MutableStateFlow(false)
    val status = MutableStateFlow("未启动")
    val port = MutableStateFlow(HttpServer.TCP_PORT)
    val localIp = MutableStateFlow("127.0.0.1")
    /** 拖拽成功后用于 UI 闪烁提示的 peerId */
    val dropFlash = MutableStateFlow<String?>(null)
    /** 401 时请求 UI 弹配对码框；transferId 非空表示可原地重试 */
    data class PinRequest(val peer: Peer, val transferId: String)
    val pinRequest = MutableStateFlow<PinRequest?>(null)
    /** 系统分享（相册/文件管理器 → 分享 → LanDrop）带进来的内容 */
    data class SharePayload(val uris: List<Uri>, val text: String?)
    val sharePayload = MutableStateFlow<SharePayload?>(null)

    fun submitShare(uris: List<Uri>, text: String?) {
        if (uris.isEmpty() && text.isNullOrBlank()) return
        sharePayload.value = SharePayload(uris, text)
    }

    fun clearShare() {
        sharePayload.value = null
    }

    var deviceId: String = ""
        private set
    var deviceName: String = ""
        private set
    var pin: String = ""
        private set
    var pinEnabled: Boolean = false
        private set

    private val peerPins = HashMap<String, String>()
    private val speedSamples = HashMap<String, Pair<Long, Long>>() // id -> (时刻ms, 已传字节)
    private val inboundIds = HashMap<String, String>()             // 上传 fileId -> transferId
    private val inboundTicks = HashMap<String, Long>()             // 上传 fileId -> 最后进度时刻
    private val inboundFileIds = HashMap<String, String>()         // transferId -> 上传 fileId
    private val controls = HashMap<String, UploadControl>()        // transferId -> 控制句柄
    private val localFiles = HashMap<String, File>()               // transferId -> 待发文件
    private val peerOf = HashMap<String, Peer>()                   // transferId -> 对端
    private var initialized = false

    fun init(ctx: Context) {
        if (initialized) return
        initialized = true
        context = ctx.applicationContext
        prefs = context.getSharedPreferences("landrop", Context.MODE_PRIVATE)
        store = InboxStore(context)

        deviceId = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString()
            .replace("-", "").take(16).also { prefs.edit().putString("deviceId", it).apply() }
        deviceName = prefs.getString("deviceName", null) ?: "${Build.MANUFACTURER} ${Build.MODEL}"
        pin = prefs.getString("pin", null) ?: randomPin().also { prefs.edit().putString("pin", it).apply() }
        pinEnabled = prefs.getBoolean("pinEnabled", false)
        prefs.getString("peerPins", null)?.let { raw ->
            runCatching {
                val obj = JSONObject(raw)
                obj.keys().forEach { k -> peerPins[k] = obj.optString(k) }
            }
        }
        files.value = store.list()
        localIp.value = NetInfo.localIp()
        sweepOutgoingCache()
    }

    // MARK: 服务端

    @Synchronized
    fun start(): Boolean {
        if (!initialized) return false
        if (running.value) return true
        val srv = HttpServer(
            store,
            { HttpServer.Identity(deviceId, deviceName, pin, pinEnabled) },
            { item ->
                files.value = store.list()
                status.value = "收到 ${item.name}"
            }
        ).also { srv ->
            srv.onUploadProgress = { fileId, name, received, total, ip ->
                inboundProgress(fileId, name, received, total, ip)
            }
            srv.onUploadAborted = { fileId ->
                val tid = inboundIds.remove(fileId)
                if (tid != null) {
                    inboundFileIds.remove(tid)
                    update(tid) { it.state = "failed"; it.error = "对端已取消"; it.speed = 0 }
                    status.value = "对端取消了传输"
                }
                inboundTicks.remove(fileId)
            }
        }
        @Suppress("UNUSED_VARIABLE")
        val bound = srv.start(HttpServer.TCP_PORT)
        if (bound == null) {
            status.value = "端口被占用，启动失败"
            return false
        }
        server = srv
        port.value = bound
        localIp.value = NetInfo.localIp()
        discovery = Discovery(deviceId, { beacon() }, { peer -> upsert(peer) }).also { it.start() }
        running.value = true
        status.value = "正在接收 · ${localIp.value}:$bound"
        return true
    }

    @Synchronized
    fun stop() {
        discovery?.stop()
        discovery = null
        server?.stop()
        server = null
        running.value = false
        peers.value = emptyList()
        status.value = "已停止"
    }

    private fun beacon(): JSONObject = JSONObject()
        .put("app", "landrop")
        .put("v", 1)
        .put("type", "announce")
        .put("id", deviceId)
        .put("name", deviceName)
        .put("platform", "android")
        .put("port", port.value)
        .put("pin_required", pinEnabled)

    private fun upsert(peer: Peer) {
        val list = peers.value.toMutableList()
        val idx = list.indexOfFirst { it.id == peer.id }
        if (idx >= 0) list[idx] = peer else list.add(peer)
        peers.value = list.sortedBy { it.name }
    }

    fun prune() {
        // 接收看门狗：15s 无数据判定对端断开
        val now = System.currentTimeMillis()
        val stalled = inboundTicks.filter { now - it.value > 6_000 }.keys.toList()
        for (fileId in stalled) {
            val tid = inboundIds.remove(fileId) ?: continue
            inboundTicks.remove(fileId)
            update(tid) { it.state = "failed"; it.error = "连接超时"; it.speed = 0 }
        }
        val alive = peers.value.filter { it.online }
        if (alive.size != peers.value.size) peers.value = alive
        files.value = store.list()
    }

    fun probe() {
        discovery?.probe()
    }

    // MARK: 发送

    fun sendFiles(uris: List<Uri>, peer: Peer) {
        for (uri in uris) {
            val (name, size) = describe(uri)
            val transfer = Transfer(fileName = name, peerName = peer.name, direction = "send", total = size)
            transfers.value = listOf(transfer) + transfers.value
            scope.launch {
                val local = copyToCache(uri, name, transfer.id)
                if (local == null) {
                    update(transfer.id) { it.state = "failed"; it.error = "无法读取文件" }
                    return@launch
                }
                val control = UploadControl(UUID.randomUUID().toString().replace("-", ""))
                controls[transfer.id] = control
                localFiles[transfer.id] = local
                peerOf[transfer.id] = peer
                update(transfer.id) { it.total = local.length() }
                runUpload(transfer.id, peer, control)
            }
        }
    }

    private fun runUpload(transferId: String, peer: Peer, control: UploadControl) {
        val file = localFiles[transferId]
        if (file == null) {
            android.util.Log.w("LanDrop", "runUpload missing cache $transferId")
            return
        }
        scope.launch {
            val displayName = transfers.value.firstOrNull { it.id == transferId }?.fileName ?: file.name
            val outcome = PeerClient(pinFor(peer)).upload(file, peer, control, displayName) { sentBytes, totalBytes ->
                progressUpdate(transferId, sentBytes, totalBytes)
            }
            when (outcome) {
                UploadOutcome.DONE -> {
                    update(transferId) { it.state = "done"; it.sent = it.total; it.speed = 0 }
                    status.value = "已发送 ${file.name}"
                    cleanup(transferId)
                }
                UploadOutcome.PAUSED -> update(transferId) { it.state = "paused"; it.speed = 0 }
                UploadOutcome.CANCELLED -> {
                    update(transferId) { it.state = "cancelled"; it.speed = 0; it.error = "已取消" }
                    cleanup(transferId)
                }
                UploadOutcome.PIN_REQUIRED -> {
                    // 保留 control/localFile，配对码保存后可原地续传
                    update(transferId) { it.state = "paused"; it.speed = 0; it.error = "需要配对码" }
                    pinRequest.value = PinRequest(peer, transferId)
                }
                UploadOutcome.FAILED -> {
                    update(transferId) { it.state = "failed"; it.speed = 0; it.error = "发送失败" }
                    cleanup(transferId)
                }
            }
        }
    }

    /** 接收方取消：关闭连接，并就地标记 */
    /** 应用退出/停止接收时清理未完成的待发缓存 */
    fun clearOutgoing() = sweepOutgoingCache()

    fun cancelReceive(t: Transfer) {
        val fileId = inboundFileIds[t.id] ?: return
        inboundIds.remove(fileId)
        inboundTicks.remove(fileId)
        inboundFileIds.remove(t.id)
        server?.cancelInbound(fileId)
        update(t.id) { it.state = "cancelled"; it.error = "已取消"; it.speed = 0 }
        status.value = "已取消接收 ${t.fileName}"
    }

    fun pauseTransfer(t: Transfer) {
        controls[t.id]?.pauseRequested = true
    }

    fun resumeTransfer(t: Transfer) {
        val control = controls[t.id] ?: return
        // 缓存被系统清理/上次清理后，不能再把状态改成 running 却永远不发送
        if (!localFiles.containsKey(t.id)) {
            update(t.id) { it.state = "failed"; it.error = "本地缓存已清理，请重新发送" }
            cleanup(t.id)
            return
        }
        control.pauseRequested = false
        control.cancelRequested = false
        update(t.id) { it.state = "running"; it.error = null }
        runUpload(t.id, peerOf[t.id] ?: return, control)
    }

    /** 配对码保存后重试被 401 拒绝的上传 */
    fun retryAfterPin(transferId: String) {
        val control = controls[transferId] ?: return
        val peer = peerOf[transferId] ?: return
        if (!localFiles.containsKey(transferId)) {
            update(transferId) { it.state = "failed"; it.error = "本地缓存已清理，请重新发送" }
            cleanup(transferId)
            return
        }
        control.pauseRequested = false
        control.cancelRequested = false
        update(transferId) { it.state = "running"; it.error = null }
        runUpload(transferId, peer, control)
    }

    fun cancelTransfer(t: Transfer) {
        val control = controls[t.id]
        if (control == null) {
            update(t.id) { it.state = "cancelled"; it.error = "已取消" }
            return
        }
        control.cancelRequested = true
        // 暂停/失败状态下没有正在跑的上传循环，必须就地结束，否则会永远卡住
        if (t.state != "running") {
            update(t.id) { it.state = "cancelled"; it.speed = 0; it.error = "已取消" }
            cleanup(t.id)
        }
        val peer = peerOf[t.id]
        if (peer != null) {
            val fid = control.fileId
            scope.launch { PeerClient(pinFor(peer)).cancelUpload(peer, fid) }
        }
    }

    private fun cleanup(transferId: String) {
        localFiles.remove(transferId)?.delete()
        controls.remove(transferId)
        peerOf.remove(transferId)
    }

    fun sendText(text: String, peer: Peer) {
        if (text.isBlank()) return
        val transfer = Transfer(fileName = "文本 ${text.length} 字", peerName = peer.name,
            direction = "send", total = text.toByteArray().size.toLong())
        transfers.value = listOf(transfer) + transfers.value
        scope.launch {
            val client = PeerClient(pinFor(peer))
            val ok = client.sendText(peer, text, null)
            if (!ok && client.pinRequiredSeen) {
                update(transfer.id) { it.state = "failed"; it.error = "需要配对码" }
                pinRequest.value = PinRequest(peer, "")
                return@launch
            }
            update(transfer.id) {
                it.state = if (ok) "done" else "failed"
                if (ok) it.sent = it.total else it.error = "发送失败"
            }
            if (ok) status.value = "文本已发送给 ${peer.name}"
        }
    }

    fun download(remote: com.landrop.android.model.RemoteFile, peer: Peer) {
        val transfer = Transfer(fileName = remote.name, peerName = peer.name,
            direction = "receive", total = remote.size)
        transfers.value = listOf(transfer) + transfers.value
        scope.launch {
            // 远端文件名不可信，先清理再落盘，避免 ../ 逃出收件箱
            val target = File(store.inbox, store.uniqueName(store.sanitize(remote.name)))
            val client = PeerClient(pinFor(peer))
            val ok = client.download(remote, peer, target) { got, totalBytes ->
                progressUpdate(transfer.id, got, totalBytes)
            }
            if (!ok) target.delete()
            if (!ok && client.pinRequiredSeen) {
                pinRequest.value = PinRequest(peer, "")
            }
            update(transfer.id) {
                it.state = if (ok) "done" else "failed"
                if (ok) { it.sent = it.total; it.speed = 0 } else it.error = "下载失败"
            }
            files.value = store.list()
            if (ok) status.value = "已接收 ${remote.name}"
        }
    }

    // MARK: 设置

    fun applySettings(name: String, pinValue: String, pinOn: Boolean) {
        deviceName = name.ifBlank { deviceName }
        if (pinValue.length == 6) pin = pinValue
        pinEnabled = pinOn
        prefs.edit()
            .putString("deviceName", deviceName)
            .putString("pin", pin)
            .putBoolean("pinEnabled", pinEnabled)
            .apply()
        status.value = "设置已保存"
    }

    fun regeneratePin() {
        pin = randomPin()
        prefs.edit().putString("pin", pin).apply()
    }

    fun pinFor(peer: Peer): String? = if (peer.pinRequired) peerPins[peer.id] else null

    fun setPin(peer: Peer, value: String) {
        peerPins[peer.id] = value
        val obj = JSONObject()
        peerPins.forEach { (k, v) -> obj.put(k, v) }
        prefs.edit().putString("peerPins", obj.toString()).apply()
    }

    fun hasPin(peer: Peer): Boolean = peerPins.containsKey(peer.id)

    // MARK: 工具

    /** 不可变更新：每次都换新对象，保证 StateFlow 因内容变化而发射 */
    private fun update(id: String, block: (Transfer) -> Unit) {
        val list = transfers.value
        val idx = list.indexOfFirst { it.id == id }
        if (idx < 0) return
        val next = list[idx].copy().also(block)
        val out = list.toMutableList()
        out[idx] = next
        transfers.value = out
    }

    /** 接收方进度：按 fileId 建一条「接收」传输记录 */
    private fun inboundProgress(fileId: String, name: String, received: Long, total: Long, ip: String) {
        var tid = inboundIds[fileId]
        if (tid == null) {
            val t = Transfer(fileName = name, peerName = ip, direction = "receive", total = total)
            transfers.value = listOf(t) + transfers.value
            tid = t.id
            inboundIds[fileId] = tid
            inboundFileIds[tid] = fileId
        }
        inboundTicks[fileId] = System.currentTimeMillis()
        progressUpdate(tid, received, total)
        if (total == 0L || received >= total) {
            inboundTicks.remove(fileId)
            inboundFileIds.remove(tid)
            update(tid!!) { it.state = "done"; it.sent = total; it.speed = 0 }
            inboundIds.remove(fileId)
        }
    }

    private val lastEmit = HashMap<String, Long>()

    /** 记录进度并计算瞬时速度（0.6/0.4 滑动平均），节流 120ms 避免过度重组 */
    private fun progressUpdate(id: String, sent: Long, total: Long) {
        val nowMs = System.currentTimeMillis()
        val done = total > 0 && sent >= total
        val prevEmit = lastEmit[id] ?: 0L
        if (!done && nowMs - prevEmit < 120) return
        lastEmit[id] = nowMs
        val now = System.currentTimeMillis()
        val prev = speedSamples[id]
        var speed = 0L
        if (prev != null) {
            val dt = now - prev.first
            if (dt >= 200) {
                val inst = ((sent - prev.second) * 1000L / dt).coerceAtLeast(0L)
                speed = inst
                speedSamples[id] = now to sent
            } else {
                speed = transfers.value.firstOrNull { it.id == id }?.speed ?: 0L
            }
        } else {
            speedSamples[id] = now to sent
        }
        val current = transfers.value.firstOrNull { it.id == id }
        if (current != null) {
            val smoothed = if (speed > 0 && current.speed > 0) (current.speed * 6 + speed * 4) / 10 else maxOf(speed, current.speed)
            update(id) { t ->
                t.sent = sent
                if (total > 0) t.total = total
                t.speed = smoothed
            }
        }
    }

    private fun describe(uri: Uri): Pair<String, Long> {
        var name = "file-${System.currentTimeMillis()}"
        var size = 0L
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIdx >= 0) name = c.getString(nameIdx) ?: name
                    if (sizeIdx >= 0 && !c.isNull(sizeIdx)) size = c.getLong(sizeIdx)
                }
            }
        }
        return name to size
    }

    fun flashDrop(peerId: String) { dropFlash.value = peerId }

    /** 是否已获得「所有文件访问」权限 */
    fun hasAllFilesAccess(): Boolean =
        android.os.Build.VERSION.SDK_INT < 30 || android.os.Environment.isExternalStorageManager()

    fun openAllFilesSettings() {
        if (android.os.Build.VERSION.SDK_INT < 30) return
        runCatching {
            val intent = android.content.Intent(
                android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:" + context.packageName)
            )
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }.onFailure {
            runCatching {
                context.startActivity(
                    android.content.Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        }
    }

    /** 清掉上次残留的待发缓存（进程被杀/失败遗留） */
    private fun sweepOutgoingCache() {
        val dir = File(context.cacheDir, "outgoing")
        if (!dir.exists()) return
        var freed = 0L
        dir.listFiles()?.forEach { f ->
            freed += f.length()
            f.delete()
        }
        if (freed > 0) android.util.Log.i("LanDrop", "清理待发缓存 ${freed / 1024 / 1024} MB")
    }

    private fun copyToCache(uri: Uri, name: String, key: String): File? = runCatching {
        val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
        val target = File(dir, key + "_" + name.takeLast(40).replace('/', '_'))
        val input = context.contentResolver.openInputStream(uri)?.let { it } ?: run {
            // 没有 URI 授权时，尝试按路径直读（需要「所有文件访问」权限）
            val path = uri.path
            if (path != null) java.io.File(path).takeIf { it.exists() }?.inputStream() else null
        }
        if (input == null) {
            android.util.Log.w("LanDrop", "读取失败: $uri (allFiles=${hasAllFilesAccess()})")
            return@runCatching null
        }
        input.use { ins -> target.outputStream().use { outs -> ins.copyTo(outs, 256 * 1024) } }
        android.util.Log.i("LanDrop", "已缓存 ${target.name} ${target.length()}B")
        target
    }.onFailure {
        android.util.Log.e("LanDrop", "copyToCache 失败: $uri", it)
    }.getOrNull()

    private fun randomPin(): String = (0 until 6).joinToString("") { (0..9).random().toString() }

    fun inboxPath(): String = if (initialized) store.inbox.absolutePath else ""
}
