package com.landrop.android

import android.content.Context
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.os.Bundle
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.landrop.android.nfc.NdefTag
import com.landrop.android.nfc.NfcSupport
import com.landrop.android.nfc.TagCodec
import com.landrop.android.nfc.TagTarget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 把一台设备的信息写进 NFC 贴纸。
 *
 * 写入后的用法：任意手机碰贴纸 → 直接弹出 LanDrop 的发送浮层；
 * 或者在相册里分享给 LanDrop → NFC 碰一碰 → 碰贴纸。
 */
class NfcWriteActivity : ComponentActivity() {

    private lateinit var target: TagTarget

    private var state by mutableStateOf<WriteState>(WriteState.Waiting)
    private var nfcAvailable by mutableStateOf(false)
    private var nfcEnabled by mutableStateOf(false)
    private var readerOn = false
    private var writing = false
    private var lastTagAt = 0L

    private val readerCallback = NfcAdapter.ReaderCallback { tag ->
        runOnUiThread { onTag(tag) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        target = readTarget(intent) ?: run {
            finish()
            return
        }
        window.statusBarColor = android.graphics.Color.WHITE
        window.navigationBarColor = android.graphics.Color.WHITE
        WindowCompat.setDecorFitsSystemWindows(window, true)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }

        nfcAvailable = NfcSupport.available(this)
        nfcEnabled = NfcSupport.enabled(this)
        if (!nfcAvailable) state = WriteState.NoHardware

        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xFF0A84FF))) {
                WriteScreen(
                    target = target,
                    state = state,
                    nfcEnabled = nfcEnabled,
                    onOpenSettings = { openNfcSettings() },
                    onDone = { finish() },
                    onAgain = {
                        state = WriteState.Waiting
                        startReader()
                    }
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        nfcAvailable = NfcSupport.available(this)
        nfcEnabled = NfcSupport.enabled(this)
        if (!nfcAvailable) {
            state = WriteState.NoHardware
        } else if (!nfcEnabled && state !is WriteState.Success && state !is WriteState.Writing) {
            state = WriteState.NfcOff
        } else if (nfcEnabled && (state is WriteState.NfcOff || state is WriteState.Waiting)) {
            if (state is WriteState.NfcOff) state = WriteState.Waiting
            startReader()
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

    private fun startReader() {
        if (readerOn || !nfcEnabled) return
        readerOn = runCatching {
            NfcSupport.adapter(this)?.enableReaderMode(this, readerCallback, NfcSupport.WRITE_FLAGS, null)
        }.isSuccess
    }

    private fun stopReader() {
        if (!readerOn) return
        runCatching { NfcSupport.adapter(this)?.disableReaderMode(this) }
        readerOn = false
    }

    private fun onTag(tag: Tag) {
        if (writing || state is WriteState.Writing) return
        val now = System.currentTimeMillis()
        if (now - lastTagAt < 800) return
        lastTagAt = now

        writing = true
        state = WriteState.Writing
        window.decorView.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)

        lifecycleScope.launch {
            val outcome = withContext(Dispatchers.IO) { NdefTag.write(target, tag) }
            writing = false
            state = if (outcome.ok) {
                window.decorView.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                WriteState.Success(
                    bytes = outcome.bytes,
                    capacity = outcome.capacity,
                    droppedName = outcome.droppedName,
                    withAar = outcome.withAar
                )
            } else {
                WriteState.Failed(
                    message = outcome.error ?: "写入失败",
                    needed = outcome.bytes,
                    capacity = outcome.capacity
                )
            }
        }
    }

    private fun openNfcSettings() {
        runCatching { startActivity(Intent(Settings.ACTION_NFC_SETTINGS)) }
            .onFailure { runCatching { startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS)) } }
    }

    companion object {
        private const val EXTRA_ID = "com.landrop.android.tag.id"
        private const val EXTRA_NAME = "com.landrop.android.tag.name"
        private const val EXTRA_PLATFORM = "com.landrop.android.tag.platform"
        private const val EXTRA_HOST = "com.landrop.android.tag.host"
        private const val EXTRA_PORT = "com.landrop.android.tag.port"
        private const val EXTRA_PIN = "com.landrop.android.tag.pin"

        fun intent(context: Context, target: TagTarget): Intent =
            Intent(context, NfcWriteActivity::class.java).apply {
                putExtra(EXTRA_ID, target.id)
                putExtra(EXTRA_NAME, target.name)
                putExtra(EXTRA_PLATFORM, target.platform)
                putExtra(EXTRA_HOST, target.host)
                putExtra(EXTRA_PORT, target.port)
                putExtra(EXTRA_PIN, target.pinRequired)
            }

        private fun readTarget(intent: Intent?): TagTarget? {
            if (intent == null) return null
            val id = intent.getStringExtra(EXTRA_ID)?.takeIf { it.isNotBlank() } ?: return null
            val host = intent.getStringExtra(EXTRA_HOST)?.takeIf { it.isNotBlank() } ?: return null
            return TagTarget(
                id = id,
                name = intent.getStringExtra(EXTRA_NAME).orEmpty(),
                platform = intent.getStringExtra(EXTRA_PLATFORM).orEmpty(),
                host = host,
                port = intent.getIntExtra(EXTRA_PORT, 47823),
                pinRequired = intent.getBooleanExtra(EXTRA_PIN, false)
            )
        }
    }
}

sealed interface WriteState {
    data object Waiting : WriteState
    data object Writing : WriteState
    data object NfcOff : WriteState
    data object NoHardware : WriteState
    data class Success(val bytes: Int, val capacity: Int, val droppedName: Boolean, val withAar: Boolean) : WriteState
    data class Failed(val message: String, val needed: Int, val capacity: Int) : WriteState
}

private val writeInk = Color(0xFF101828)
private val writeSub = Color(0xFF667085)

@Composable
private fun WriteScreen(
    target: TagTarget,
    state: WriteState,
    nfcEnabled: Boolean,
    onOpenSettings: () -> Unit,
    onDone: () -> Unit,
    onAgain: () -> Unit
) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Color(0xFFF4F5F9))
            .padding(20.dp)
            .animateContentSize()
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("NFC 贴纸", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = writeInk)
                Text("写入后，碰一下就能把文件发到这台设备", fontSize = 11.sp, color = writeSub)
            }
            TextButton(onClick = onDone) { Text("关闭", color = writeSub) }
        }

        Spacer(Modifier.height(16.dp))

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            color = Color.White
        ) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(46.dp).background(Color(0xFFEFF6FF), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        when (target.platform.lowercase()) {
                            "macos" -> "💻"
                            "harmony", "harmonyos" -> "📲"
                            else -> "📱"
                        },
                        fontSize = 20.sp
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        target.name.ifBlank { "这台设备" },
                        fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = writeInk,
                        maxLines = 1, overflow = TextOverflow.Ellipsis
                    )
                    Text("${target.host}:${target.port}", fontSize = 11.sp, color = writeSub)
                }
                Text("${TagCodec.ndefBytes(target)} 字节", fontSize = 10.sp, color = Color(0xFF98A2B3))
            }
        }

        Spacer(Modifier.height(6.dp))
        Text(
            if (target.pinRequired) "对方开启了配对码：第一次碰一碰发送时需要输入一次，之后会记住。"
            else "建议用 NTAG213 及以上容量的贴纸（144 字节即可）。",
            fontSize = 10.sp, color = Color(0xFF98A2B3)
        )

        Spacer(Modifier.height(24.dp))

        when (state) {
            is WriteState.NoHardware -> NoticeCard(
                "这台手机没有 NFC",
                "写入贴纸需要带 NFC 的手机；也可以让其它装了 LanDrop 的手机来写。"
            )
            is WriteState.NfcOff -> NoticeCard(
                "NFC 已关闭",
                "打开 NFC 后把贴纸靠近手机背面即可写入。",
                action = "去开启",
                onAction = onOpenSettings
            )
            is WriteState.Waiting -> WaitingCard(active = true, nfcEnabled = nfcEnabled)
            is WriteState.Writing -> WaitingCard(active = false, nfcEnabled = nfcEnabled, label = "正在写入，别移开贴纸…")
            is WriteState.Success -> SuccessCard(state, onAgain = onAgain, onDone = onDone)
            is WriteState.Failed -> FailedCard(state, onAgain = onAgain, onDone = onDone)
        }
    }
}

@Composable
private fun WaitingCard(active: Boolean, nfcEnabled: Boolean, label: String = "把贴纸靠近手机背面") {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Color.White)
            .padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        BigNfcGlyph(active = active)
        Spacer(Modifier.height(18.dp))
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = writeInk)
        Spacer(Modifier.height(6.dp))
        Text(
            if (nfcEnabled) "听到提示音就写好了；写完把手机/贴纸分开，别一直贴着"
            else "请先打开 NFC",
            fontSize = 11.sp, color = writeSub, textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun SuccessCard(state: WriteState.Success, onAgain: () -> Unit, onDone: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Color.White)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(54.dp).background(Color(0xFFDCFCE7), CircleShape),
            contentAlignment = Alignment.Center
        ) { Text("✓", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color(0xFF15803D)) }
        Spacer(Modifier.height(12.dp))
        Text("贴纸已写好", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = writeInk)
        Spacer(Modifier.height(4.dp))
        Text(
            if (state.capacity > 0) "占用 ${state.bytes} / ${state.capacity} 字节" else "占用 ${state.bytes} 字节",
            fontSize = 11.sp, color = writeSub
        )
        if (state.droppedName) {
            Spacer(Modifier.height(6.dp))
            Text("贴纸容量较小，已省略设备名，碰一碰时会自动补上", fontSize = 10.sp, color = Color(0xFFB45309))
        }
        if (!state.withAar) {
            Spacer(Modifier.height(6.dp))
            Text("未写入应用唤醒记录：碰一碰时由系统按链接拉起 LanDrop", fontSize = 10.sp, color = Color(0xFF98A2B3))
        }
        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = onAgain, modifier = Modifier.weight(1f), shape = RoundedCornerShape(14.dp)) {
                Text("再写一张")
            }
            Button(onClick = onDone, modifier = Modifier.weight(1f), shape = RoundedCornerShape(14.dp)) {
                Text("完成")
            }
        }
    }
}

@Composable
private fun FailedCard(state: WriteState.Failed, onAgain: () -> Unit, onDone: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Color.White)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(54.dp).background(Color(0xFFFEE4E2), CircleShape),
            contentAlignment = Alignment.Center
        ) { Text("!", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color(0xFFB42318)) }
        Spacer(Modifier.height(12.dp))
        Text("没能写入", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = writeInk)
        Spacer(Modifier.height(6.dp))
        Text(state.message, fontSize = 11.sp, color = writeSub, textAlign = TextAlign.Center)
        if (state.capacity > 0 && state.needed > state.capacity) {
            Text(
                "需要至少 ${state.needed} 字节，这张只有 ${state.capacity} 字节",
                fontSize = 10.sp, color = Color(0xFFB45309)
            )
        }
        Spacer(Modifier.height(18.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onClick = onDone, modifier = Modifier.weight(1f)) { Text("关闭", color = writeSub) }
            Button(onClick = onAgain, modifier = Modifier.weight(1f), shape = RoundedCornerShape(14.dp)) {
                Text("再试一次")
            }
        }
    }
}

@Composable
private fun NoticeCard(title: String, detail: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(24.dp))
            .background(Color.White)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            Modifier.size(54.dp).background(Color(0xFFFEF3C7), CircleShape),
            contentAlignment = Alignment.Center
        ) { Text("📡", fontSize = 22.sp) }
        Spacer(Modifier.height(12.dp))
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = writeInk)
        Spacer(Modifier.height(6.dp))
        Text(detail, fontSize = 11.sp, color = writeSub, textAlign = TextAlign.Center)
        if (action != null) {
            Spacer(Modifier.height(12.dp))
            Button(onClick = onAction, shape = RoundedCornerShape(14.dp)) { Text(action) }
        }
    }
}

@Composable
private fun BigNfcGlyph(active: Boolean) {
    val tint = Color(0xFF0A84FF)
    Canvas(Modifier.size(96.dp)) {
        val center = Offset(size.width * 0.34f, size.height / 2f)
        val stroke = Stroke(width = size.minDimension * 0.075f, cap = StrokeCap.Round)
        for (i in 0..2) {
            val radius = size.minDimension * (0.18f + 0.19f * i)
            drawArc(
                color = tint.copy(alpha = if (active) 1f else 0.45f),
                startAngle = -52f,
                sweepAngle = 104f,
                useCenter = false,
                topLeft = Offset(center.x - radius, center.y - radius),
                size = Size(radius * 2, radius * 2),
                style = stroke
            )
        }
        drawCircle(tint, radius = size.minDimension * 0.07f, center = center)
    }
}
