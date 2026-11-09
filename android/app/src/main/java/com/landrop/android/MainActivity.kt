package com.landrop.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.DragEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.landrop.android.model.FileItem
import com.landrop.android.model.Peer
import com.landrop.android.model.Platform
import com.landrop.android.model.Transfer
import com.landrop.android.model.formatSize
import com.landrop.android.nfc.NfcSupport
import com.landrop.android.nfc.TagCodec
import com.landrop.android.nfc.TagTarget
import com.landrop.android.service.TransferService
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LanDropCore.init(applicationContext)

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            registerForActivityResult(ActivityResultContracts.RequestPermission()) { }.launch(
                Manifest.permission.POST_NOTIFICATIONS
            )
        }

        runCatching {
            if (Build.VERSION.SDK_INT >= 26) {
                startForegroundService(Intent(this, TransferService::class.java))
            } else {
                startService(Intent(this, TransferService::class.java))
            }
        }

        val dropListener = android.view.View.OnDragListener { _, event ->
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED -> true
                DragEvent.ACTION_DRAG_ENTERED -> true
                DragEvent.ACTION_DROP -> {
                    val clip = event.clipData
                    val uris = ArrayList<Uri>()
                    if (clip != null) {
                        for (i in 0 until clip.itemCount) {
                            val item = clip.getItemAt(i)
                            item.uri?.let { u ->
                                if (u.scheme == "content" || u.scheme == "file") uris.add(u)
                            }
                            // 部分文件管理器把 uri-list 放在 text 里
                            item.text?.split('\n', '\r')?.forEach { raw ->
                                val t = raw.trim()
                                if (t.startsWith("content://") || t.startsWith("file://")) {
                                    runCatching { uris.add(Uri.parse(t)) }
                                }
                            }
                            item.intent?.data?.let { u ->
                                if (u.scheme == "content" || u.scheme == "file") uris.add(u)
                            }
                        }
                    }
                    android.util.Log.i(
                        "LanDrop",
                        "drop at (${event.x}, ${event.y}) items=${clip?.itemCount ?: 0} uris=${uris.size} types=${clip?.description}"
                    )
                    if (uris.isEmpty()) return@OnDragListener false
                    val hitId = DropTargets.bounds.entries
                        .firstOrNull { it.value.contains(androidx.compose.ui.geometry.Offset(event.x, event.y)) }
                        ?.key
                    val peer = hitId?.let { id -> LanDropCore.peers.value.firstOrNull { it.id == id } }
                    if (peer == null) {
                        android.widget.Toast.makeText(
                            applicationContext, "请把文件拖到某台设备的卡片上", android.widget.Toast.LENGTH_SHORT
                        ).show()
                        false
                    } else {
                        android.util.Log.i("LanDrop", "drop -> ${peer.name} (${uris.size} 个文件)")
                        LanDropCore.flashDrop(peer.id)
                        LanDropCore.sendFiles(uris, peer)
                        true
                    }
                }
                else -> true
            }
        }
        // 只挂 decorView：content 子 View 先收到事件，坐标是相对它自己的，会导致命中错行
        window.decorView.setOnDragListener(dropListener)

        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xFF0A84FF))) {
                LanDropScreen()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}

/** 记录每个设备行在窗口中的位置，用于拖放命中测试 */
object DropTargets {
    val bounds = mutableMapOf<String, Rect>()
}

private val cardColor = Color.White
private val bgColor = Color(0xFFF4F5F9)
private val ink = Color(0xFF101828)
private val sub = Color(0xFF667085)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LanDropScreen() {
    val ctx = LocalContext.current
    val peers by LanDropCore.peers.collectAsState()
    val files by LanDropCore.files.collectAsState()
    val transfers by LanDropCore.transfers.collectAsState()
    val running by LanDropCore.running.collectAsState()
    val status by LanDropCore.status.collectAsState()
    val ip by LanDropCore.localIp.collectAsState()
    val pinReq by LanDropCore.pinRequest.collectAsState()

    var tab by remember { mutableIntStateOf(0) }
    var selectedId by remember { mutableStateOf<String?>(null) }
    var showSettings by remember { mutableStateOf(false) }
    var showText by remember { mutableStateOf(false) }
    var showNfc by remember { mutableStateOf(false) }
    var showBgHint by remember { mutableStateOf(false) }
    var pinPromptFor by remember { mutableStateOf<Peer?>(null) }

    val selected: Peer? = peers.firstOrNull { it.id == selectedId } ?: peers.firstOrNull()

    LaunchedEffect(Unit) {
        while (true) {
            LanDropCore.prune()
            delay(5000)
        }
    }

    LaunchedEffect(Unit) {
        if (!LanDropCore.ignoringBatteryOptimizations() && !LanDropCore.bgPromptSeen()) {
            showBgHint = true
        }
    }

    // 双入口：系统图库（Photo Picker）与系统文件选择（SAF）
    var pendingPeer by remember { mutableStateOf<Peer?>(null) }
    var showSourcePicker by remember { mutableStateOf(false) }

    fun deliver(uris: List<Uri>) {
        val peer = pendingPeer
        if (peer != null && uris.isNotEmpty()) {
            LanDropCore.sendFiles(uris, peer)
            tab = 2
        }
        pendingPeer = null
    }

    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        deliver(uris)
    }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(9)) { uris ->
        deliver(uris)
    }

    fun beginSend(peer: Peer) {
        if (peer.pinRequired && !LanDropCore.hasPin(peer)) {
            pinPromptFor = peer
        } else {
            pendingPeer = peer
            showSourcePicker = true
        }
    }

    Scaffold(
        containerColor = bgColor,
        topBar = {
            TopAppBar(
                title = { Text("LanDrop", fontWeight = FontWeight.Bold) },
                actions = {
                    TextButton(onClick = { showNfc = true }) {
                        Text("贴纸", fontSize = 12.sp, color = Color(0xFF344054))
                    }
                    TextButton(onClick = { showText = true }) {
                        Text("文本", fontSize = 12.sp, color = Color(0xFF344054))
                    }
                    IconButton(onClick = { LanDropCore.probe() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "刷新")
                    }
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Default.Settings, contentDescription = "设置")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.White)
            )
        },
        floatingActionButton = {
            if (tab == 0 && peers.isNotEmpty()) {
                ExtendedFloatingActionButton(
                    onClick = { selected?.let { beginSend(it) } },
                    containerColor = Color(0xFF0A84FF),
                    contentColor = Color.White,
                    icon = { Icon(Icons.Default.Send, null) },
                    text = { Text("发送文件") }
                )
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            DeviceCard(running, ip, LanDropCore.port.collectAsState().value) {
                if (running) LanDropCore.stop() else LanDropCore.start()
            }
            TabRow(selectedTabIndex = tab, containerColor = bgColor) {
                Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("设备 ${peers.size}") })
                Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("收件箱 ${files.size}") })
                Tab(selected = tab == 2, onClick = { tab = 2 }, text = { Text("传输") })
            }
            when (tab) {
                0 -> PeersList(peers, selected?.id) { peer ->
                    selectedId = peer.id
                    beginSend(peer)
                }
                1 -> FilesList(files) { item -> openFile(ctx, item) }
                else -> TransfersList(transfers)
            }
            Text(
                status,
                fontSize = 10.sp,
                color = sub,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
            )
        }
    }

    if (showSettings) SettingsDialog(onDismiss = { showSettings = false })
    if (showBgHint) {
        AlertDialog(
            onDismissRequest = { showBgHint = false; LanDropCore.markBgPromptSeen() },
            title = { Text("让接收服务留在后台") },
            text = {
                Text(
                    "关闭电池优化后，LanDrop 才能在息屏、切后台时持续接收文件；" +
                        "vivo / 小米 / OPPO 等系统还需要在「自启动」里允许 LanDrop，重启后才不会被拦。",
                    fontSize = 12.sp, color = sub, lineHeight = 18.sp
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    LanDropCore.markBgPromptSeen()
                    showBgHint = false
                    LanDropCore.requestIgnoreBatteryOptimizations()
                }) { Text("去关闭") }
            },
            dismissButton = {
                TextButton(onClick = {
                    LanDropCore.markBgPromptSeen()
                    showBgHint = false
                }) { Text("稍后") }
            }
        )
    }
    if (showNfc) {
        NfcTargetDialog(
            onDismiss = { showNfc = false },
            onPick = { target ->
                showNfc = false
                ctx.startActivity(NfcWriteActivity.intent(ctx, target))
            }
        )
    }
    if (showText) {
        TextDialog(
            onDismiss = { showText = false },
            onSend = { text ->
                selected?.let { LanDropCore.sendText(text, it) }
                showText = false
                tab = 2
            }
        )
    }
    if (showSourcePicker) {
        AlertDialog(
            onDismissRequest = { showSourcePicker = false; pendingPeer = null },
            title = { Text("选择文件来源") },
            text = { Text("「图库」调用系统照片选择器（无需存储权限），「文件」打开系统文件管理器，可选任意类型。") },
            confirmButton = {
                TextButton(onClick = {
                    showSourcePicker = false
                    photoPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                    )
                }) { Text("图库") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showSourcePicker = false
                    filePicker.launch(arrayOf("*/*"))
                }) { Text("文件") }
            }
        )
    }

    val dialogPeer = pinPromptFor ?: pinReq?.peer
    if (dialogPeer != null) {
        val autoReq = if (pinPromptFor == null) pinReq else null
        PinDialog(dialogPeer,
            onDismiss = {
                pinPromptFor = null
                LanDropCore.pinRequest.value = null
            },
            onSaved = {
                pinPromptFor = null
                LanDropCore.pinRequest.value = null
                if (autoReq == null) {
                    pendingPeer = dialogPeer
                    showSourcePicker = true
                } else if (autoReq.transferId.isNotEmpty()) {
                    LanDropCore.retryAfterPin(autoReq.transferId)
                } else {
                    android.widget.Toast.makeText(ctx, "配对码已保存，请重新发送", android.widget.Toast.LENGTH_SHORT).show()
                }
            })
    }
}

@Composable
private fun DeviceCard(running: Boolean, ip: String, port: Int, onToggle: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().padding(14.dp),
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = cardColor),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp)
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(52.dp)
                    .background(Brush.linearGradient(listOf(Color(0xFF4C8DFF), Color(0xFF8B5CF6))), CircleShape),
                contentAlignment = Alignment.Center
            ) { Text("⇅", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold) }

            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(LanDropCore.deviceName, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(if (running) Color(0xFF22C55E) else Color(0xFF9CA3AF), CircleShape))
                    Spacer(Modifier.width(5.dp))
                    Text(if (running) "$ip:$port" else "未启动", fontSize = 11.sp, color = sub)
                }
                if (LanDropCore.pinEnabled) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Lock, null, Modifier.size(10.dp), tint = Color(0xFFB45309))
                        Text(" ${LanDropCore.pin}", fontSize = 10.sp, color = Color(0xFFB45309))
                    }
                }
            }

            Button(
                onClick = onToggle,
                shape = RoundedCornerShape(20.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (running) Color(0xFFFEE4E2) else Color(0xFFDCFCE7),
                    contentColor = if (running) Color(0xFFB42318) else Color(0xFF15803D)
                )
            ) { Text(if (running) "停止" else "启动", fontSize = 12.sp) }
        }
    }
}

@Composable
private fun PeersList(peers: List<Peer>, selectedId: String?, onPick: (Peer) -> Unit) {
    if (peers.isEmpty()) {
        EmptyState("📡", "还没有发现设备", "确认对方已打开 LanDrop，并与本机在同一 Wi-Fi")
        return
    }
    LazyColumn(contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(peers, key = { it.id }) { peer ->
            val flashId by LanDropCore.dropFlash.collectAsState()
            val isFlash = flashId == peer.id
            val scale by animateFloatAsState(if (isFlash) 1.02f else 1f, label = "dropScale")
            LaunchedEffect(isFlash) {
                if (isFlash) {
                    delay(650)
                    if (LanDropCore.dropFlash.value == peer.id) LanDropCore.dropFlash.value = null
                }
            }
            Row(
                Modifier.fillMaxWidth()
                    .graphicsLayer { scaleX = scale; scaleY = scale }
                    .onGloballyPositioned { coords ->
                        DropTargets.bounds[peer.id] = coords.boundsInWindow()
                    }
                    .background(cardColor, RoundedCornerShape(14.dp))
                    .clickable { onPick(peer) }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier.size(38.dp).background(Color(0xFFF2F4F7), CircleShape),
                    contentAlignment = Alignment.Center
                ) { Text(if (peer.platform == Platform.MACOS) "💻" else if (peer.platform == Platform.HARMONY) "📲" else "📱", fontSize = 18.sp) }
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(peer.name, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (peer.pinRequired) {
                            Spacer(Modifier.width(4.dp))
                            Icon(Icons.Default.Lock, null, Modifier.size(11.dp), tint = Color(0xFFB45309))
                        }
                    }
                    Text("${peer.platform.label} · ${peer.endpoint}", fontSize = 10.sp, color = Color(0xFF98A2B3))
                }
                Text(
                    if (peer.id == selectedId) "已选中" else "发送",
                    fontSize = 11.sp,
                    color = if (peer.id == selectedId) Color(0xFF0A84FF) else sub
                )
            }
        }
    }
}

@Composable
private fun FilesList(files: List<FileItem>, onOpen: (FileItem) -> Unit) {
    if (files.isEmpty()) {
        EmptyState("📥", "收件箱是空的", "别人发来的文件会出现在这里")
        return
    }
    LazyColumn(contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items(files, key = { it.id + it.size }) { item ->
            Row(
                Modifier.fillMaxWidth().background(cardColor, RoundedCornerShape(12.dp)).padding(11.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(if (item.kind == "text") "📝" else "📄", fontSize = 17.sp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f).clickable { onOpen(item) }) {
                    Text(item.name, fontSize = 13.sp, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${formatSize(item.size)} · ${java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(item.mtime))}", fontSize = 10.sp, color = Color(0xFF98A2B3))
                }
                IconButton(onClick = { LanDropCore.store.delete(item); LanDropCore.prune() }) {
                    Icon(Icons.Default.Delete, "删除", Modifier.size(18.dp), tint = Color(0xFFB42318))
                }
            }
        }
    }
}

@Composable
private fun TransfersList(transfers: List<Transfer>) {
    if (transfers.isEmpty()) {
        EmptyState("⇅", "还没有传输记录", "选择设备后点「发送文件」，或发送一段文本")
        return
    }
    LazyColumn(contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items(transfers, key = { it.id }) { t ->
            Column(Modifier.fillMaxWidth().background(cardColor, RoundedCornerShape(12.dp)).padding(11.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (t.direction == "send") "⬆️" else "⬇️", fontSize = 13.sp)
                    Spacer(Modifier.width(6.dp))
                    Text(t.fileName, fontSize = 12.sp, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(t.peerName, fontSize = 10.sp, color = Color(0xFF98A2B3))
                    if (t.direction == "receive" && t.state == "running") {
                        TextButton(
                            onClick = { LanDropCore.cancelReceive(t) },
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                            modifier = Modifier.height(28.dp)
                        ) { Text("✕", fontSize = 13.sp, color = Color(0xFFB42318)) }
                    }
                    if (t.direction == "send" && t.state == "preparing") {
                        TextButton(
                            onClick = { LanDropCore.cancelTransfer(t) },
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                            modifier = Modifier.height(28.dp)
                        ) { Text("✕", fontSize = 13.sp, color = Color(0xFFB42318)) }
                    }
                    if (t.direction == "send" && (t.state == "running" || t.state == "paused")) {
                        TextButton(
                            onClick = {
                                if (t.state == "paused") LanDropCore.resumeTransfer(t)
                                else LanDropCore.pauseTransfer(t)
                            },
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                            modifier = Modifier.height(28.dp)
                        ) { Text(if (t.state == "paused") "▶ 继续" else "⏸ 暂停", fontSize = 11.sp, color = Color(0xFF344054)) }
                        TextButton(
                            onClick = { LanDropCore.cancelTransfer(t) },
                            contentPadding = PaddingValues(horizontal = 6.dp, vertical = 0.dp),
                            modifier = Modifier.height(28.dp)
                        ) { Text("✕", fontSize = 13.sp, color = Color(0xFFB42318)) }
                    }
                }
                Spacer(Modifier.height(5.dp))
                if (t.state == "running" || t.state == "paused" || t.state == "preparing") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (t.state == "preparing") {
                            LinearProgressIndicator(
                                modifier = Modifier.weight(1f),
                                color = Color(0xFF0A84FF)
                            )
                        } else {
                            LinearProgressIndicator(
                                progress = { t.progress },
                                modifier = Modifier.weight(1f),
                                color = if (t.state == "paused") Color(0xFFF59E0B) else Color(0xFF0A84FF)
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        val pct = (t.progress * 100).toInt()
                        val err = t.error
                        Text(
                            when (t.state) {
                                "preparing" -> "准备中…"
                                "paused" -> if (err != null) "$err · $pct%" else "已暂停 · $pct%"
                                else -> "$pct% · ${t.speedText}"
                            },
                            fontSize = 10.sp,
                            color = when (t.state) {
                                "preparing" -> sub
                                "paused" -> Color(0xFFB45309)
                                else -> sub
                            }
                        )
                    }
                } else {
                    Text(
                        if (t.state == "done") "已完成 · ${formatSize(t.total)}" else (t.error ?: "失败"),
                        fontSize = 10.sp,
                        color = if (t.state == "done") Color(0xFF15803D) else Color(0xFFB42318)
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyState(icon: String, title: String, subtitle: String) {
    Column(
        Modifier.fillMaxSize().padding(30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(icon, fontSize = 40.sp)
        Spacer(Modifier.height(8.dp))
        Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = ink)
        Text(subtitle, fontSize = 11.sp, color = Color(0xFF98A2B3), modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun SettingsDialog(onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(LanDropCore.deviceName) }
    var pin by remember { mutableStateOf(LanDropCore.pin) }
    var pinOn by remember { mutableStateOf(LanDropCore.pinEnabled) }
    var showDonate by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("设置") },
        text = {
            Column(Modifier.heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("设备名") }, singleLine = true)
                Spacer(Modifier.height(4.dp))
                TextButton(
                    onClick = { showDonate = true },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("❤ 自愿捐赠（微信）", fontSize = 12.sp, color = Color(0xFF07C160))
                }
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("配对码保护", fontSize = 14.sp)
                        Text("对方发送前需输入 6 位数字", fontSize = 10.sp, color = sub)
                    }
                    Switch(checked = pinOn, onCheckedChange = { pinOn = it })
                }
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = pin, onValueChange = { if (it.length <= 6) pin = it },
                        label = { Text("配对码") }, singleLine = true,
                        enabled = pinOn,
                        modifier = Modifier.weight(1f),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
                    )
                    Spacer(Modifier.width(8.dp))
                    TextButton(onClick = {
                        LanDropCore.regeneratePin()
                        pin = LanDropCore.pin
                    }) { Text("换一个") }
                }
                Spacer(Modifier.height(12.dp))
                var batteryExempt by remember { mutableStateOf(LanDropCore.ignoringBatteryOptimizations()) }
                LaunchedEffect(Unit) {
                    while (true) {
                        batteryExempt = LanDropCore.ignoringBatteryOptimizations()
                        delay(1500)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("电池优化", fontSize = 14.sp)
                        Text(
                            if (batteryExempt) "已关闭，息屏/后台也能持续接收"
                            else "未关闭，系统可能随时停掉接收服务",
                            fontSize = 10.sp,
                            color = if (batteryExempt) Color(0xFF15803D) else Color(0xFFB45309)
                        )
                    }
                    TextButton(onClick = { LanDropCore.requestIgnoreBatteryOptimizations() }) {
                        Text(if (batteryExempt) "已关闭" else "去关闭")
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("开机自启动", fontSize = 14.sp)
                        Text(
                            "重启/升级后自动拉起接收服务；系统里还需允许「自启动」",
                            fontSize = 10.sp, color = sub
                        )
                    }
                    TextButton(onClick = { LanDropCore.openAutoStartSettings() }) { Text("去开启") }
                }
                Spacer(Modifier.height(8.dp))
                val granted = LanDropCore.hasAllFilesAccess()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("所有文件访问", fontSize = 14.sp)
                        Text(
                            if (granted) "已授权，可直接读取拖入的文件" else "拖拽/读取其他应用的文件需要此权限",
                            fontSize = 10.sp, color = sub
                        )
                    }
                    TextButton(onClick = { LanDropCore.openAllFilesSettings() }) {
                        Text(if (granted) "已开启" else "去授权")
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text("协议为明文 HTTP，配对码只用于防误触，不加密内容。", fontSize = 10.sp, color = Color(0xFF98A2B3))
            }
        },
        confirmButton = {
            TextButton(onClick = {
                LanDropCore.applySettings(name.trim(), pin, pinOn)
                onDismiss()
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )

    if (showDonate) {
        DonateDialog(onDismiss = { showDonate = false })
    }
}

@Composable
private fun DonateDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("自愿捐赠") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    "LanDrop 免费、无广告、不登录、不上传云端。\n如果它帮到了你，可以自愿捐赠；不捐赠不影响任何功能。",
                    fontSize = 11.sp,
                    color = sub,
                    lineHeight = 16.sp
                )
                Spacer(Modifier.height(10.dp))
                Image(
                    painter = painterResource(R.drawable.donate_wechat),
                    contentDescription = "微信收款码",
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 420.dp),
                    contentScale = ContentScale.Fit
                )
                Spacer(Modifier.height(8.dp))
                Text("收款方：皓子(**皓) · 微信支付", fontSize = 10.sp, color = sub)
                Text("捐赠完全自愿，请量力而行。", fontSize = 10.sp, color = sub)
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("关闭") }
        }
    )
}

@Composable
private fun TextDialog(onDismiss: () -> Unit, onSend: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("发送文本") },
        text = {
            Column {
                Text("文本会落成 .txt 存进对方收件箱", fontSize = 11.sp, color = sub)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = text, onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth().height(140.dp),
                    placeholder = { Text("链接、验证码、一段配置…") }
                )
            }
        },
        confirmButton = {
            TextButton(enabled = text.isNotEmpty(), onClick = { onSend(text) }) { Text("发送") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
private fun NfcTargetDialog(onDismiss: () -> Unit, onPick: (TagTarget) -> Unit) {
    val ctx = LocalContext.current
    val peers by LanDropCore.peers.collectAsState()
    val running by LanDropCore.running.collectAsState()
    val ip by LanDropCore.localIp.collectAsState()
    val port by LanDropCore.port.collectAsState()
    val supported = remember { NfcSupport.available(ctx) }

    val local = TagTarget(
        id = LanDropCore.deviceId,
        name = LanDropCore.deviceName,
        platform = "android",
        host = ip,
        port = port,
        pinRequired = LanDropCore.pinEnabled
    )
    val localReady = supported && running && ip != "127.0.0.1"

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("NFC 贴纸") },
        text = {
            Column(Modifier.heightIn(max = 470.dp).verticalScroll(rememberScrollState())) {
                Text(
                    "选一台设备，把它的信息写进贴纸。之后在相册/文件里分享给 LanDrop，选「NFC 碰一碰」，碰一下贴纸就能发送。",
                    fontSize = 11.sp, color = sub, lineHeight = 16.sp
                )
                if (!supported) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "这台手机没有 NFC，写不了贴纸；换成带 NFC 的手机才能写。",
                        fontSize = 11.sp, color = Color(0xFFB45309)
                    )
                }
                Spacer(Modifier.height(12.dp))
                Text("本机", fontSize = 10.sp, color = Color(0xFF98A2B3))
                Spacer(Modifier.height(4.dp))
                NfcTargetRow(
                    icon = "📱",
                    name = "${LanDropCore.deviceName}（本机）",
                    detail = if (localReady) "$ip:$port" else "先启动接收并连上 Wi-Fi",
                    enabled = localReady
                ) { onPick(local) }

                Spacer(Modifier.height(10.dp))
                Text("附近设备", fontSize = 10.sp, color = Color(0xFF98A2B3))
                Spacer(Modifier.height(4.dp))
                if (peers.isEmpty()) {
                    Text(
                        "还没有发现设备。确认对方已打开 LanDrop，并与本机在同一 Wi-Fi。",
                        fontSize = 10.sp, color = Color(0xFF98A2B3), modifier = Modifier.padding(vertical = 6.dp)
                    )
                } else {
                    peers.forEach { peer ->
                        NfcTargetRow(
                            icon = if (peer.platform == Platform.MACOS) "💻" else if (peer.platform == Platform.HARMONY) "📲" else "📱",
                            name = peer.name,
                            detail = "${peer.platform.label} · ${peer.endpoint}",
                            enabled = supported
                        ) {
                            onPick(
                                TagTarget(
                                    id = peer.id,
                                    name = peer.name,
                                    platform = peer.platform.name.lowercase(),
                                    host = peer.host,
                                    port = peer.port,
                                    pinRequired = peer.pinRequired
                                )
                            )
                        }
                    }
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    "贴纸约 ${TagCodec.ndefBytes(local, withAar = false)} 字节起，NTAG213（144 字节）就够用。" +
                        "只写设备名、地址和端口，不含配对码。",
                    fontSize = 10.sp, color = Color(0xFF98A2B3), lineHeight = 15.sp
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

@Composable
private fun NfcTargetRow(icon: String, name: String, detail: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(
                if (enabled) Color(0xFFF7F8FA) else Color(0xFFF2F4F7),
                RoundedCornerShape(12.dp)
            )
            .clickable(enabled = enabled) { onClick() }
            .padding(horizontal = 11.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(icon, fontSize = 16.sp)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(
                name, fontSize = 13.sp, color = if (enabled) ink else sub,
                maxLines = 1, overflow = TextOverflow.Ellipsis
            )
            Text(detail, fontSize = 10.sp, color = Color(0xFF98A2B3), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            if (enabled) "写入 ›" else "不可用",
            fontSize = 11.sp,
            color = if (enabled) Color(0xFF0A84FF) else Color(0xFF98A2B3)
        )
    }
}

@Composable
private fun PinDialog(peer: Peer, onDismiss: () -> Unit, onSaved: () -> Unit) {
    var value by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("输入配对码") },
        text = {
            Column {
                Text("「${peer.name}」开启了配对码保护。", fontSize = 12.sp, color = sub)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = value,
                    onValueChange = { if (it.length <= 6) value = it },
                    label = { Text("6 位数字") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true
                )
            }
        },
        confirmButton = {
            TextButton(enabled = value.length == 6, onClick = {
                LanDropCore.setPin(peer, value)
                onSaved()
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }
    )
}

private fun openFile(ctx: Context, item: FileItem) {
    val mime = LanDropCore.store.mimeOf(item.name)
    val uri: Uri = item.uri
        ?: FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", item.file)
    val view = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mime)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    val ok = runCatching { ctx.startActivity(view); true }.getOrDefault(false)
    if (!ok) {
        // 没有能直接打开的应用就退化成「分享」
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching {
            ctx.startActivity(Intent.createChooser(send, "打开方式").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure {
            android.widget.Toast.makeText(ctx, "没有可打开该文件的应用", android.widget.Toast.LENGTH_SHORT).show()
        }
    }
}
