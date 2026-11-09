package com.landrop.android

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewModelScope
import com.landrop.android.model.Peer
import com.landrop.android.model.Platform
import com.landrop.android.model.Transfer
import com.landrop.android.nfc.NdefTag
import com.landrop.android.nfc.NfcSupport
import com.landrop.android.nfc.TagCodec
import com.landrop.android.nfc.TagTarget
import com.landrop.android.net.PeerClient
import com.landrop.android.service.TransferService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * 系统分享目标：相册/文件管理器 → 分享 → LanDrop →
 * 这里弹一个**半透明**的二级菜单（不是切到主界面），可以选「NFC 碰一碰」，
 * 也可以直接点附近设备，之后走原来的传输流程。
 *
 * 同一个 Activity 也负责"先碰贴纸、再选文件"：贴纸里的 NDEF 会直接拉起它。
 */
class ShareTargetActivity : ComponentActivity() {

    private lateinit var vm: ShareSheetViewModel

    private var nfcAvailable by mutableStateOf(false)
    private var nfcEnabled by mutableStateOf(false)
    private var readerOn = false
    private var lastTagAt = 0L
    private var resolveToken = 0

    private val readerCallback = NfcAdapter.ReaderCallback { tag ->
        runOnUiThread { onTagRead(tag) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LanDropCore.init(applicationContext)
        vm = ViewModelProvider(this)[ShareSheetViewModel::class.java]
        configureWindow()

        val parsed = sharePayload(intent)
        if (parsed != null && vm.payload.isEmpty()) vm.load(parsed.first, parsed.second)
        val target = if (savedInstanceState == null) targetFromIntent(intent) else null

        ensureService()
        Thread { LanDropCore.start() }.apply { isDaemon = true }.start()

        if (savedInstanceState == null) {
            when {
                target != null -> {
                    // 贴纸直接拉起：从第一秒就按「贴纸会话」处理，占住 reader mode，
                    // 否则贴纸一直贴着会被系统反复派发
                    vm.tagFlow = true
                    tagUid(intent)?.let { LanDropCore.markTag(it) }
                    resolveTarget(target)
                }
                parsed == null -> {
                    finish()
                    return
                }
            }
        }

        nfcAvailable = NfcSupport.available(this)
        nfcEnabled = NfcSupport.enabled(this)

        onBackPressedDispatcher.addCallback(this) {
            if (vm.phase is SheetPhase.Sending) {
                toast("已转到后台继续发送")
            }
            finish()
        }

        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xFF0A84FF))) {
                ShareSheetRoot(
                    vm = vm,
                    nfcAvailable = nfcAvailable,
                    nfcEnabled = nfcEnabled,
                    onDismiss = { dismiss() },
                    onScan = { beginScan() },
                    onNfcSettings = { openNfcSettings() },
                    onPeer = { peer ->
                        LanDropCore.upsertPeer(peer)
                        afterResolved(peer)
                    },
                    onPin = { peer, pin ->
                        LanDropCore.setPin(peer, pin)
                        LanDropCore.pinRequest.value = null
                        val stuck = vm.lastIds.mapNotNull { id ->
                            LanDropCore.transfers.value.firstOrNull {
                                it.id == id && it.error == "需要配对码"
                            }
                        }
                        if (stuck.isNotEmpty()) {
                            stuck.forEach { LanDropCore.retryAfterPin(it.id) }
                            vm.phase = SheetPhase.Sending(peer, stuck.map { it.id })
                        } else {
                            afterResolved(peer)
                        }
                    },
                    onRetry = { vm.lastTarget?.let { resolveTarget(it) } },
                    onPickedFiles = { uris -> sendPicked(uris) },
                    onCancelScan = {
                        resolveToken++
                        vm.phase = SheetPhase.Choose()
                        syncReader()
                    },
                    onCancelSending = {
                        val current = vm.phase
                        if (current is SheetPhase.Sending) {
                            current.ids.forEach { id ->
                                LanDropCore.transfers.value.firstOrNull { it.id == id }
                                    ?.let { LanDropCore.cancelTransfer(it) }
                            }
                        }
                    },
                    onAllFinished = { failed ->
                        vm.phase = if (failed > 0) {
                            SheetPhase.Failed("有 $failed 项没发出去", "检查对方是否还在接收，或稍后重试。")
                        } else {
                            SheetPhase.Done(vm.lastSentCount)
                        }
                    },
                    onBackground = {
                        toast("已转到后台继续发送")
                        finish()
                    }
                )
            }
        }

        lifecycleScope.launch {
            delay(350)
            LanDropCore.probe()
            delay(1200)
            LanDropCore.probe()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val parsed = sharePayload(intent)
        val target = targetFromIntent(intent)
        when {
            parsed != null -> {
                resolveToken++
                vm.load(parsed.first, parsed.second)
                stopReader()
            }
            target != null -> {
                val uid = tagUid(intent)
                if (uid != null && LanDropCore.isTagRepeat(uid)) {
                    android.util.Log.i("LanDrop", "同一张贴纸的重复派发，忽略")
                    showTagHint()
                    return
                }
                if (uid != null) LanDropCore.markTag(uid)
                vm.tagFlow = true
                syncReader()
                // 贴纸已经在感应区时，系统可能一直重复派发；只处理真正需要响应的状态
                when (val phase = vm.phase) {
                    is SheetPhase.Choose -> if (phase.quick) return
                    is SheetPhase.Scanning, is SheetPhase.Failed -> {
                        android.util.Log.i("LanDrop", "NDEF 派发 -> ${target.name}")
                        resolveTarget(target)
                    }
                    else -> Unit
                }
            }
            else -> finish()
        }
    }

    override fun onResume() {
        super.onResume()
        nfcAvailable = NfcSupport.available(this)
        nfcEnabled = NfcSupport.enabled(this)
        if (vm.phase is SheetPhase.Scanning) {
            if (nfcEnabled) startReader() else {
                vm.note = "NFC 已关闭"
                stopReader()
            }
        } else {
            syncReader()
        }
    }

    override fun onPause() {
        super.onPause()
        stopReader()
    }

    override fun onDestroy() {
        stopReader()
        super.onDestroy()
    }

    // MARK: - 界面骨架

    private fun configureWindow() {
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
    }

    private fun dismiss() {
        if (vm.phase is SheetPhase.Sending) toast("已转到后台继续发送")
        finish()
    }

    private fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
    }

    private fun ensureService() {
        runCatching {
            val intent = Intent(this, TransferService::class.java)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        }
    }

    // MARK: - NFC

    private fun beginScan() {
        val adapter = NfcSupport.adapter(this)
        if (adapter == null) {
            toast("这台设备没有 NFC")
            return
        }
        if (!adapter.isEnabled) {
            toast("请先打开 NFC")
            openNfcSettings()
            return
        }
        vm.note = null
        vm.phase = SheetPhase.Scanning
        startReader()
    }

    private fun startReader() {
        if (readerOn) return
        if (!NfcSupport.enabled(this)) return
        readerOn = runCatching {
            NfcSupport.adapter(this)?.enableReaderMode(this, readerCallback, NfcSupport.READ_FLAGS, null)
        }.onFailure {
            android.util.Log.w("LanDrop", "enableReaderMode 失败，改用系统 NDEF 派发", it)
        }.isSuccess
    }

    private fun stopReader() {
        if (!readerOn) return
        runCatching { NfcSupport.adapter(this)?.disableReaderMode(this) }
        readerOn = false
    }

    /**
     * 贴纸还贴在手机背面时**不能**关掉 reader mode：一旦关闭，系统会按普通
     * NDEF 派发再拉起一个 ShareTargetActivity（新 task、空 payload），
     * 正在分享的文件就丢了。所以只在离开扫描/发送流程时才关。
     */
    private fun syncReader() {
        val active = when (vm.phase) {
            is SheetPhase.Scanning, is SheetPhase.Connecting, is SheetPhase.NeedPin,
            is SheetPhase.Sending, is SheetPhase.Done, is SheetPhase.Failed -> true
            else -> false
        }
        // 贴纸拉起的会话全程占着 reader mode：贴纸一直贴着也不会触发系统 NDEF 重复派发
        val keep = active || vm.tagFlow
        if (keep && nfcEnabled) startReader() else stopReader()
    }

    private fun onTagRead(tag: Tag) {
        if (vm.phase !is SheetPhase.Scanning) return
        val now = System.currentTimeMillis()
        if (now - lastTagAt < 700) return
        lastTagAt = now

        val uid = tag.id?.joinToString("") { "%02x".format(it) }
        if (uid != null) {
            if (LanDropCore.isTagRepeat(uid)) {
                showTagHint()
                return
            }
            LanDropCore.markTag(uid)
        }

        val target = NdefTag.read(tag)
        if (target == null) {
            vm.note = "这张贴纸里没有 LanDrop 设备信息"
            return
        }
        window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        vm.tagFlow = true
        vm.note = null
        vm.tagHint = null
        // 刻意不 stopReader()：见 syncReader() 的注释
        resolveTarget(target)
    }

    private fun showTagHint() {
        val text = "别一直贴着贴纸：碰一下就拿开，否则会反复弹出"
        if (vm.tagHint == text) return
        vm.tagHint = text
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
    }

    private fun openNfcSettings() {
        runCatching { startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) }
            .onFailure {
                runCatching { startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS)) }
            }
    }

    // MARK: - 解析 / 发送

    private fun resolveTarget(target: TagTarget) {
        val token = ++resolveToken
        vm.lastTarget = target
        vm.phase = SheetPhase.Connecting(target)
        vm.note = null
        lifecycleScope.launch {
            val peer = withContext(Dispatchers.IO) { confirm(target) }
            if (token != resolveToken) return@launch
            if (peer == null) {
                vm.phase = SheetPhase.Failed(
                    "连不上「${target.name.ifBlank { target.host }}」",
                    "碰一碰只在同一 Wi-Fi 下可用：确认对方 LanDrop 正在接收，并且贴纸写的是它当前的地址。"
                )
                return@launch
            }
            LanDropCore.upsertPeer(peer)
            vm.resolved = peer
            afterResolved(peer)
        }
    }

    /** 用 /v1/info 验一下贴纸没有写错人，顺便拿到最新的名字/端口 */
    private fun confirm(target: TagTarget): Peer? {
        val base = Peer(
            id = target.id,
            name = target.name.ifBlank { target.host },
            platform = Platform.from(target.platform),
            host = target.host,
            port = target.port,
            pinRequired = target.pinRequired
        )
        val info: JSONObject = PeerClient(LanDropCore.storedPin(target.id)).info(base) ?: return null
        val id = info.optString("id")
        if (id.isNotEmpty() && id != target.id) return null
        return base.copy(
            name = info.optString("name").ifBlank { base.name },
            platform = Platform.from(info.optString("platform", target.platform)),
            port = info.optInt("port", target.port),
            pinRequired = info.optBoolean("pin_required", target.pinRequired)
        )
    }

    private fun afterResolved(peer: Peer) {
        vm.resolved = peer
        when {
            peer.pinRequired && !LanDropCore.hasPin(peer) -> {
                vm.phase = SheetPhase.NeedPin(peer)
                syncReader()
            }
            hasPayload() -> sendTo(peer)
            // 先碰贴纸、后选文件：留在浮层里让用户挑
            else -> vm.phase = SheetPhase.Choose(quick = true)
        }
    }

    private fun hasPayload(): Boolean =
        vm.payload.uris.isNotEmpty() || !vm.payload.text.isNullOrBlank()

    private fun sendTo(peer: Peer) {
        val uris = vm.payload.uris
        val text = vm.payload.text
        ensureService()
        when {
            uris.isNotEmpty() -> {
                // 系统给的读取授权在 task 结束时可能被回收，能转持久就转
                uris.forEach {
                    runCatching {
                        contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
                val ids = LanDropCore.sendFiles(uris, peer)
                vm.lastSentCount = ids.size
                vm.lastIds = ids
                vm.phase = SheetPhase.Sending(peer, ids)
            }
            !text.isNullOrBlank() -> {
                LanDropCore.sendText(text, peer)
                vm.lastSentCount = 1
                vm.phase = SheetPhase.Done(1)
            }
            else -> finish()
        }
    }

    private fun sendPicked(uris: List<Uri>) {
        val peer = vm.resolved ?: return
        vm.payload = SharePayload(uris.distinct(), null)
        sendTo(peer)
    }

    // MARK: - Intent 解析

    private fun sharePayload(intent: Intent?): Pair<List<Uri>, String?>? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return null

        val uris = LinkedHashSet<Uri>()
        fun add(value: Uri?) {
            if (value != null && (value.scheme == "content" || value.scheme == "file")) uris.add(value)
        }

        if (intent.action == Intent.ACTION_SEND) {
            add(
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
            )
        } else {
            val many = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            }
            many?.forEach { add(it) }
        }
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri)
        }

        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        if (uris.isEmpty() && text.isNullOrBlank()) return null
        return uris.toList() to text
    }

    private fun tagUid(intent: Intent?): String? {
        if (intent == null) return null
        val direct = intent.getByteArrayExtra(NfcAdapter.EXTRA_ID)
        val tag = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }
        val bytes = direct ?: tag?.id
        return bytes?.joinToString("") { "%02x".format(it) }
    }

    private fun targetFromIntent(intent: Intent?): TagTarget? {
        if (intent == null) return null
        return when (intent.action) {
            NfcAdapter.ACTION_NDEF_DISCOVERED -> {
                val messages: Array<*>? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
                }
                NdefTag.read(messages?.firstOrNull() as? NdefMessage)
                    ?: TagCodec.parseUri(intent.dataString)
            }
            Intent.ACTION_VIEW -> TagCodec.parseUri(intent.dataString)
            else -> null
        }
    }
}

// MARK: - 状态

data class SharePayload(
    val uris: List<Uri> = emptyList(),
    val text: String? = null
) {
    fun isEmpty(): Boolean = uris.isEmpty() && text.isNullOrBlank()
}

sealed interface SheetPhase {
    data class Choose(val quick: Boolean = false) : SheetPhase
    data object Scanning : SheetPhase
    data class Connecting(val target: TagTarget) : SheetPhase
    data class NeedPin(val peer: Peer) : SheetPhase
    data class Sending(val peer: Peer, val ids: List<String>) : SheetPhase
    data class Done(val count: Int) : SheetPhase
    data class Failed(val title: String, val detail: String) : SheetPhase
}

class ShareSheetViewModel(app: Application) : AndroidViewModel(app) {
    var payload by mutableStateOf(SharePayload())
    var phase by mutableStateOf<SheetPhase>(SheetPhase.Choose())
    var resolved by mutableStateOf<Peer?>(null)
    var lastTarget by mutableStateOf<TagTarget?>(null)
    var note by mutableStateOf<String?>(null)
    /** 贴纸一直贴着时给用户的提示 */
    var tagHint by mutableStateOf<String?>(null)
    var titles by mutableStateOf<List<String>>(emptyList())
    var lastSentCount: Int = 0
    var lastIds: List<String> = emptyList()
    /** 本次浮层是由贴纸拉起的：完成页不自动关闭，避免贴纸还在感应区时又被系统派发一次 */
    var tagFlow by mutableStateOf(false)

    fun load(uris: List<Uri>, text: String?) {
        payload = SharePayload(uris.distinct(), text?.takeIf { it.isNotBlank() })
        phase = SheetPhase.Choose()
        resolved = null
        note = null
        lastSentCount = 0
        titles = emptyList()
        val snapshot = payload.uris
        if (snapshot.isNotEmpty()) {
            viewModelScope.launch(Dispatchers.IO) {
                val names = snapshot.take(3).map { queryName(it) }
                titles = names
            }
        }
    }

    private fun queryName(uri: Uri): String {
        runCatching {
            getApplication<Application>().contentResolver
                .query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        }.getOrNull()?.takeIf { it.isNotBlank() }?.let { return it }
        return uri.lastPathSegment ?: "文件"
    }
}

// MARK: - 浮层

private val sheetInk = Color(0xFF101828)
private val sheetSub = Color(0xFF667085)
private val sheetLine = Color(0xFFEAECF0)
private val sheetBlue = Color(0xFF0A84FF)

@Composable
private fun ShareSheetRoot(
    vm: ShareSheetViewModel,
    nfcAvailable: Boolean,
    nfcEnabled: Boolean,
    onDismiss: () -> Unit,
    onScan: () -> Unit,
    onNfcSettings: () -> Unit,
    onPeer: (Peer) -> Unit,
    onPin: (Peer, String) -> Unit,
    onRetry: () -> Unit,
    onPickedFiles: (List<Uri>) -> Unit,
    onCancelScan: () -> Unit,
    onCancelSending: () -> Unit,
    onAllFinished: (Int) -> Unit,
    onBackground: () -> Unit
) {
    val phase = vm.phase
    val peers by LanDropCore.peers.collectAsState()
    val transfers by LanDropCore.transfers.collectAsState()

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(9)
    ) { uris -> if (uris.isNotEmpty()) onPickedFiles(uris) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris -> if (uris.isNotEmpty()) onPickedFiles(uris) }

    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.26f))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) { onDismiss() }
        )

        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .imePadding()
                .navigationBarsPadding()
                .padding(horizontal = 10.dp, vertical = 10.dp)
                .animateContentSize()
        ) {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(26.dp),
                color = Color.White,
                shadowElevation = 24.dp
            ) {
                Column(Modifier.padding(horizontal = 18.dp, vertical = 14.dp)) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Box(
                            Modifier
                                .width(38.dp)
                                .height(4.dp)
                                .clip(CircleShape)
                                .background(Color(0xFFE4E7EC))
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                    vm.tagHint?.let { hint ->
                        Row(
                            Modifier.fillMaxWidth()
                                .background(Color(0xFFFFFAEB), RoundedCornerShape(12.dp))
                                .padding(horizontal = 12.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("⚠", fontSize = 12.sp)
                            Spacer(Modifier.width(7.dp))
                            Text(hint, fontSize = 11.sp, color = Color(0xFFB45309), lineHeight = 15.sp)
                        }
                        Spacer(Modifier.height(12.dp))
                    }
                    when (phase) {
                        is SheetPhase.Choose -> ChooseContent(
                            vm = vm,
                            peers = peers,
                            quick = phase.quick,
                            nfcAvailable = nfcAvailable,
                            nfcEnabled = nfcEnabled,
                            onScan = onScan,
                            onNfcSettings = onNfcSettings,
                            onPeer = onPeer,
                            onPickPhotos = {
                                photoPicker.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                                )
                            },
                            onPickFiles = { filePicker.launch(arrayOf("*/*")) },
                            onDismiss = onDismiss
                        )
                        is SheetPhase.Scanning -> ScanningContent(
                            note = vm.note,
                            nfcEnabled = nfcEnabled,
                            onNfcSettings = onNfcSettings,
                            onCancel = onCancelScan
                        )
                        is SheetPhase.Connecting -> ConnectingContent(phase.target, onCancel = {
                            onCancelScan()
                        })
                        is SheetPhase.NeedPin -> PinContent(peer = phase.peer, onSave = onPin, onCancel = onDismiss)
                        is SheetPhase.Sending -> SendingContent(
                            peer = phase.peer,
                            ids = phase.ids,
                            transfers = transfers,
                            onBackground = onBackground,
                            onCancel = onCancelSending,
                            onPinNeeded = { peer -> vm.phase = SheetPhase.NeedPin(peer) },
                            onFinished = onAllFinished
                        )
                        is SheetPhase.Done -> DoneContent(
                            count = phase.count,
                            autoClose = !vm.tagFlow,
                            onDismiss = onDismiss
                        )
                        is SheetPhase.Failed -> FailedContent(phase.title, phase.detail, onRetry, onDismiss)
                    }
                }
            }
        }
    }
}

private fun idsDone(ids: List<String>, transfers: List<Transfer>): Boolean {
    if (ids.isEmpty()) return true
    return ids.all { id ->
        val t = transfers.firstOrNull { it.id == id } ?: return@all false
        t.state == "done" || t.state == "failed" || t.state == "cancelled"
    }
}

@Composable
private fun ChooseContent(
    vm: ShareSheetViewModel,
    peers: List<Peer>,
    quick: Boolean,
    nfcAvailable: Boolean,
    nfcEnabled: Boolean,
    onScan: () -> Unit,
    onNfcSettings: () -> Unit,
    onPeer: (Peer) -> Unit,
    onPickPhotos: () -> Unit,
    onPickFiles: () -> Unit,
    onDismiss: () -> Unit
) {
    val peer = vm.resolved
    if (quick && peer != null) {
        Text("发送到", fontSize = 11.sp, color = sheetSub)
        Text(peer.name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = onPickPhotos,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(14.dp)
            ) { Text("选择图片") }
            OutlinedButton(
                onClick = onPickFiles,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(14.dp)
            ) { Text("选择文件") }
        }
        Spacer(Modifier.height(16.dp))
        SectionLabel("或发送到其它设备", onRefresh = { LanDropCore.probe() })
    } else {
        Text("发送到", fontSize = 11.sp, color = sheetSub)
        Text(summary(vm), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(14.dp))
        if (nfcAvailable) {
            NfcTile(enabled = nfcEnabled, onClick = if (nfcEnabled) onScan else onNfcSettings)
            Spacer(Modifier.height(16.dp))
        }
        SectionLabel(if (nfcAvailable) "或选择附近设备" else "选择附近设备", onRefresh = { LanDropCore.probe() })
    }

    PeerRows(peers, onPeer)

    Spacer(Modifier.height(6.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = onDismiss) { Text("取消", color = sheetSub) }
    }
}

@Composable
private fun SectionLabel(text: String, onRefresh: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(text, fontSize = 11.sp, color = sheetSub, modifier = Modifier.weight(1f))
        TextButton(onClick = onRefresh, contentPadding = PaddingValues(horizontal = 6.dp)) {
            Icon(Icons.Default.Refresh, null, Modifier.size(13.dp), tint = sheetSub)
            Spacer(Modifier.width(3.dp))
            Text("刷新", fontSize = 11.sp, color = sheetSub)
        }
    }
}

@Composable
private fun PeerRows(peers: List<Peer>, onPeer: (Peer) -> Unit) {
    if (peers.isEmpty()) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
            Text("正在搜索附近设备…", fontSize = 12.sp, color = sheetSub)
        }
        return
    }
    Column(Modifier.heightIn(max = 236.dp).verticalScroll(rememberScrollState())) {
        peers.take(8).forEach { peer ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { onPeer(peer) }
                    .padding(horizontal = 6.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(34.dp).background(Color(0xFFF2F4F7), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        when (peer.platform) {
                            Platform.MACOS -> "💻"
                            Platform.HARMONY -> "📲"
                            else -> "📱"
                        },
                        fontSize = 16.sp
                    )
                }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(peer.name, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = sheetInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${peer.platform.label} · ${peer.endpoint}", fontSize = 10.sp, color = Color(0xFF98A2B3))
                }
                if (peer.pinRequired) {
                    Text("🔒", fontSize = 11.sp)
                    Spacer(Modifier.width(6.dp))
                }
                Text("›", fontSize = 18.sp, color = Color(0xFF98A2B3))
            }
        }
    }
}

@Composable
private fun NfcTile(enabled: Boolean, onClick: () -> Unit) {
    val bg = if (enabled) Color(0xFFEFF6FF) else Color(0xFFF5F6F8)
    val tint = if (enabled) sheetBlue else Color(0xFF98A2B3)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(bg)
            .clickable { onClick() }
            .padding(14.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(42.dp).background(tint.copy(alpha = 0.12f), CircleShape),
                contentAlignment = Alignment.Center
            ) { NfcGlyph(active = false, tint = tint, modifier = Modifier.size(24.dp)) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("NFC 碰一碰", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (enabled) sheetInk else sheetSub)
                Text(
                    if (!enabled) "NFC 未开启，点这里去打开"
                    else "把手机靠近贴纸，立即发送",
                    fontSize = 11.sp, color = sheetSub
                )
            }
            Text("›", fontSize = 20.sp, color = tint)
        }
    }
}

@Composable
private fun ScanningContent(
    note: String?,
    nfcEnabled: Boolean,
    onNfcSettings: () -> Unit,
    onCancel: () -> Unit
) {
    Text("NFC 碰一碰", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk)
    Text("碰一下就拿开，别让手机一直贴着", fontSize = 12.sp, color = sheetSub)

    Box(Modifier.fillMaxWidth().padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
        NfcGlyph(active = true, tint = sheetBlue, modifier = Modifier.size(72.dp))
    }

    Text(
        note ?: "贴纸里存着目标设备，碰一下就开始发送，不用回到主界面。",
        fontSize = 11.sp,
        color = if (note != null) Color(0xFFB42318) else Color(0xFF98A2B3),
        modifier = Modifier.fillMaxWidth()
    )

    if (!nfcEnabled) {
        Spacer(Modifier.height(10.dp))
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0xFFFFFAEB)).padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("NFC 已关闭", fontSize = 12.sp, color = Color(0xFFB45309), modifier = Modifier.weight(1f))
            TextButton(onClick = onNfcSettings) { Text("去开启", fontSize = 12.sp) }
        }
    }

    Spacer(Modifier.height(8.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = onCancel) { Text("取消", color = sheetSub) }
    }
}

@Composable
private fun ConnectingContent(target: TagTarget, onCancel: () -> Unit) {
    Text("正在连接", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk)
    Text(target.name.ifBlank { target.host }, fontSize = 12.sp, color = sheetSub, maxLines = 1, overflow = TextOverflow.Ellipsis)
    Row(
        Modifier.fillMaxWidth().padding(vertical = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.5.dp)
        Spacer(Modifier.width(10.dp))
        Text("正在确认贴纸对应的设备…", fontSize = 12.sp, color = sheetSub)
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = onCancel) { Text("取消", color = sheetSub) }
    }
}

@Composable
private fun PinContent(peer: Peer, onSave: (Peer, String) -> Unit, onCancel: () -> Unit) {
    var value by remember(peer.id) { mutableStateOf("") }
    Text("输入配对码", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk)
    Text("「${peer.name}」开启了配对码保护，输入一次后这台设备会记住。", fontSize = 11.sp, color = sheetSub)
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(
        value = value,
        onValueChange = { if (it.length <= 6 && it.all(Char::isDigit)) value = it },
        label = { Text("6 位数字") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
        modifier = Modifier.fillMaxWidth()
    )
    Spacer(Modifier.height(8.dp))
    Row {
        TextButton(onClick = onCancel) { Text("取消", color = sheetSub) }
        Spacer(Modifier.weight(1f))
        Button(
            enabled = value.length == 6,
            onClick = { onSave(peer, value) },
            shape = RoundedCornerShape(14.dp)
        ) { Text("保存并发送") }
    }
}

@Composable
private fun SendingContent(
    peer: Peer,
    ids: List<String>,
    transfers: List<Transfer>,
    onBackground: () -> Unit,
    onCancel: () -> Unit,
    onPinNeeded: (Peer) -> Unit,
    onFinished: (Int) -> Unit
) {
    val mine = remember(ids, transfers) { transfers.filter { it.id in ids } }
    val finished = idsDone(ids, transfers)
    val failed = mine.count { it.state == "failed" || it.state == "cancelled" }
    val pinRejected = mine.any { it.error == "需要配对码" }

    LaunchedEffect(finished, failed) {
        if (finished) {
            delay(500)
            onFinished(failed)
        }
    }

    Text("正在发送到", fontSize = 11.sp, color = sheetSub)
    Text(peer.name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
    Spacer(Modifier.height(12.dp))

    Column(Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
        ids.forEach { id ->
            val t = mine.firstOrNull { it.id == id }
            Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        t?.fileName ?: "准备中…",
                        fontSize = 12.sp, color = sheetInk,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        when (t?.state) {
                            "done" -> "完成"
                            "failed" -> "失败"
                            "cancelled" -> "已取消"
                            "preparing" -> "准备中…"
                            else -> "${t?.progress?.let { (it * 100).toInt() } ?: 0}%"
                        },
                        fontSize = 10.sp,
                        color = when (t?.state) {
                            "done" -> Color(0xFF15803D)
                            "failed", "cancelled" -> Color(0xFFB42318)
                            else -> sheetSub
                        }
                    )
                }
                Spacer(Modifier.height(5.dp))
                if (t?.state == "preparing") {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape),
                        color = sheetBlue,
                        trackColor = Color(0xFFF2F4F7)
                    )
                } else {
                    LinearProgressIndicator(
                        progress = { t?.progress ?: 0f },
                        modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape),
                        color = when (t?.state) {
                            "done" -> Color(0xFF22C55E)
                            "failed", "cancelled" -> Color(0xFFEF4444)
                            else -> sheetBlue
                        },
                        trackColor = Color(0xFFF2F4F7)
                    )
                }
            }
        }
    }

    if (pinRejected) {
        Row(
            Modifier.fillMaxWidth().padding(top = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("配对码不对，发送被拒绝", fontSize = 11.sp, color = Color(0xFFB42318), modifier = Modifier.weight(1f))
            TextButton(onClick = { onPinNeeded(peer) }) { Text("重新输入", fontSize = 12.sp) }
        }
    }

    Spacer(Modifier.height(6.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onCancel) { Text("全部取消", fontSize = 12.sp, color = Color(0xFFB42318)) }
        Spacer(Modifier.weight(1f))
        Button(onClick = onBackground, shape = RoundedCornerShape(14.dp)) { Text("后台发送") }
    }
}

@Composable
private fun DoneContent(count: Int, autoClose: Boolean, onDismiss: () -> Unit) {
    if (autoClose) {
        LaunchedEffect(Unit) {
            delay(1300)
            onDismiss()
        }
    }
    Column(
        Modifier.fillMaxWidth().padding(vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(44.dp).background(Color(0xFFDCFCE7), CircleShape),
            contentAlignment = Alignment.Center
        ) { Text("✓", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color(0xFF15803D)) }
        Spacer(Modifier.height(8.dp))
        Text(if (count > 1) "已发送 $count 项" else "已发送", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = sheetInk)
        Text(
            if (autoClose) "可以继续做别的事了" else "拿开手机后点「完成」关闭",
            fontSize = 11.sp, color = sheetSub
        )
        if (!autoClose) {
            Spacer(Modifier.height(12.dp))
            Button(onClick = onDismiss, shape = RoundedCornerShape(14.dp)) { Text("完成") }
        }
    }
}

@Composable
private fun FailedContent(title: String, detail: String, onRetry: () -> Unit, onDismiss: () -> Unit) {
    Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = sheetInk)
    Spacer(Modifier.height(6.dp))
    Text(detail, fontSize = 11.sp, color = sheetSub, lineHeight = 16.sp)
    Spacer(Modifier.height(10.dp))
    Row {
        TextButton(onClick = onDismiss) { Text("取消", color = sheetSub) }
        Spacer(Modifier.weight(1f))
        Button(onClick = onRetry, shape = RoundedCornerShape(14.dp)) { Text("重试") }
    }
}

/** 三段弧的 NFC 图标，扫描时呼吸 */
@Composable
private fun NfcGlyph(active: Boolean, tint: Color, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "nfc")
    val t by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1500, easing = LinearEasing)),
        label = "nfcPulse"
    )
    Canvas(modifier) {
        val center = Offset(size.width * 0.32f, size.height / 2f)
        val stroke = Stroke(width = size.minDimension * 0.085f, cap = StrokeCap.Round)
        for (i in 0..2) {
            val radius = size.minDimension * (0.2f + 0.19f * i)
            val alpha = if (active) {
                val phase = (t + i * 0.22f) % 1f
                (1f - phase).coerceIn(0.18f, 1f)
            } else {
                0.9f - i * 0.18f
            }
            drawArc(
                color = tint.copy(alpha = alpha),
                startAngle = -52f,
                sweepAngle = 104f,
                useCenter = false,
                topLeft = Offset(center.x - radius, center.y - radius),
                size = Size(radius * 2, radius * 2),
                style = stroke
            )
        }
        drawCircle(tint, radius = size.minDimension * 0.075f, center = center)
    }
}

private fun summary(vm: ShareSheetViewModel): String {
    val uris = vm.payload.uris
    return when {
        uris.size > 1 -> "${uris.size} 个文件"
        uris.size == 1 -> vm.titles.firstOrNull()?.let { if (it.length > 26) it.take(25) + "…" else it } ?: "1 个文件"
        !vm.payload.text.isNullOrBlank() -> "文本 · ${vm.payload.text!!.length} 字"
        else -> ""
    }
}
