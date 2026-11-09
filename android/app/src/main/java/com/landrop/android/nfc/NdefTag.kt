package com.landrop.android.nfc

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable

/**
 * NDEF 读写：把 [TagTarget] 写成一张"碰一碰"贴纸，或从贴纸里读回目标设备。
 *
 * 贴纸内容是一条 URI 记录 `landrop://tap?...`，可选再附一条 AAR
 * （Android Application Record），这样应用没装/未启动时系统也知道该拉起谁。
 * 容量不够时按顺序降级：带 AAR → 不带 AAR → 省略设备名。
 */
object NdefTag {
    /** 与 app/build.gradle.kts 的 applicationId 一致；AAR 靠它定位应用 */
    const val PACKAGE = "com.landrop.android"

    data class Built(
        val message: NdefMessage,
        val bytes: Int,
        val droppedName: Boolean,
        val withAar: Boolean
    )

    data class WriteOutcome(
        val ok: Boolean,
        val bytes: Int,
        val capacity: Int,
        val droppedName: Boolean = false,
        val withAar: Boolean = false,
        val error: String? = null
    )

    /**
     * 按容量挑一种能塞下的写法；[maxBytes] <= 0 表示容量未知（未格式化的生标签）。
     */
    fun build(target: TagTarget, maxBytes: Int): Built? {
        val variants = listOf(
            Triple(true, true, false),   // 有名字 + AAR
            Triple(true, false, false),  // 有名字
            Triple(false, false, true)   // 省掉名字
        )
        for ((includeName, aar, dropped) in variants) {
            val uri = TagCodec.buildUri(target, includeName = includeName)
            val message = runCatching {
                val records = if (aar) {
                    arrayOf(NdefRecord.createUri(uri), NdefRecord.createApplicationRecord(PACKAGE))
                } else {
                    arrayOf(NdefRecord.createUri(uri))
                }
                NdefMessage(records)
            }.getOrNull() ?: continue
            val bytes = message.toByteArray().size
            if (maxBytes <= 0 || bytes <= maxBytes) {
                return Built(message, bytes, dropped, aar)
            }
        }
        return null
    }

    /** 写入失败时给用户看的最小字节数（不含 AAR、不含名字） */
    fun minimumBytes(target: TagTarget): Int = TagCodec.ndefBytes(target, withAar = false, includeName = false)

    fun read(tag: Tag): TagTarget? {
        val cached = runCatching { Ndef.get(tag)?.cachedNdefMessage }.getOrNull()
        return read(cached)
    }

    fun read(message: NdefMessage?): TagTarget? {
        if (message == null) return null
        for (record in message.records) {
            val uri = runCatching { record.toUri()?.toString() }.getOrNull() ?: continue
            TagCodec.parseUri(uri)?.let { return it }
        }
        return null
    }

    fun write(target: TagTarget, tag: Tag): WriteOutcome {
        val ndef = runCatching { Ndef.get(tag) }.getOrNull()
        if (ndef != null) {
            return try {
                ndef.connect()
                val capacity = ndef.maxSize
                if (!ndef.isWritable) {
                    WriteOutcome(false, 0, capacity, error = "这张贴纸是只读的，换一张可写的")
                } else {
                    val built = build(target, capacity)
                    if (built == null) {
                        WriteOutcome(
                            false, minimumBytes(target), capacity,
                            error = "贴纸容量不足：这张只有 $capacity 字节"
                        )
                    } else {
                        ndef.writeNdefMessage(built.message)
                        WriteOutcome(true, built.bytes, capacity, built.droppedName, built.withAar)
                    }
                }
            } catch (e: Exception) {
                WriteOutcome(false, 0, 0, error = describe(e))
            } finally {
                runCatching { ndef.close() }
            }
        }

        val formattable = runCatching { NdefFormatable.get(tag) }.getOrNull()
        if (formattable != null) {
            return try {
                formattable.connect()
                val built = build(target, 0)
                if (built == null) {
                    WriteOutcome(false, minimumBytes(target), 0, error = "贴纸容量不足")
                } else {
                    formattable.format(built.message)
                    val capacity = runCatching { Ndef.get(tag)?.maxSize }.getOrNull() ?: 0
                    WriteOutcome(true, built.bytes, capacity, built.droppedName, built.withAar)
                }
            } catch (e: Exception) {
                WriteOutcome(false, 0, 0, error = describe(e))
            } finally {
                runCatching { formattable.close() }
            }
        }

        val techs = runCatching {
            tag.techList?.joinToString("/") { it.substringAfterLast('.') }
        }.getOrNull().orEmpty()
        return WriteOutcome(
            false, minimumBytes(target), 0,
            error = if (techs.isEmpty()) "这张贴纸不支持 NDEF，换一张 NTAG 系列试试"
            else "这张贴纸不支持 NDEF（识别为 $techs），换一张 NTAG213/215 试试"
        )
    }

    private fun describe(e: Exception): String = when (e) {
        is android.nfc.TagLostException -> "贴纸移开了，请贴稳后重试"
        is java.io.IOException -> "写入中断：${e.message ?: "贴纸不可写"}"
        is android.nfc.FormatException -> "贴纸格式不支持"
        else -> "写入失败：${e.message ?: e.javaClass.simpleName}"
    }
}

/** NFC 适配器的可用性判断，Activity 与 Compose 共用 */
object NfcSupport {
    val READ_FLAGS: Int = NfcAdapter.FLAG_READER_NFC_A or
        NfcAdapter.FLAG_READER_NFC_B or
        NfcAdapter.FLAG_READER_NFC_F or
        NfcAdapter.FLAG_READER_NFC_V or
        NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS

    /**
     * 写入不能跳过系统的 NDEF 预读：SKIP_NDEF_CHECK 会让 Tag 的 tech list 里
     * 没有 Ndef，Ndef.get() 直接返回 null，普通 NTAG 也会被误判成"不支持 NDEF"。
     */
    val WRITE_FLAGS: Int = READ_FLAGS

    fun adapter(context: android.content.Context): NfcAdapter? =
        runCatching { NfcAdapter.getDefaultAdapter(context) }.getOrNull()

    fun available(context: android.content.Context): Boolean = adapter(context) != null

    fun enabled(context: android.content.Context): Boolean =
        runCatching { adapter(context)?.isEnabled == true }.getOrDefault(false)
}
