package com.landrop.android.nfc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TagCodecTest {

    private val mac = TagTarget(
        id = "3f2a9c81d4b7e065",
        name = "MacBook Pro",
        platform = "macos",
        host = "192.168.1.23",
        port = 47823,
        pinRequired = false
    )

    @Test
    fun asciiRoundTrip() {
        val uri = TagCodec.buildUri(mac)
        assertTrue(uri.startsWith("landrop://tap?v=1&id=3f2a9c81d4b7e065"))
        assertEquals(mac, TagCodec.parseUri(uri))
    }

    @Test
    fun chineseAndSpecialCharsRoundTrip() {
        val target = mac.copy(name = "我的 Mac & \"书房\"=1", platform = "android", pinRequired = true)
        val uri = TagCodec.buildUri(target)
        // 载荷必须是纯 ASCII，否则写进 NDEF 后不同读卡器解析不一致
        assertTrue(uri.all { it.code in 0x20..0x7e })
        val parsed = TagCodec.parseUri(uri)
        assertNotNull(parsed)
        assertEquals(target.name, parsed!!.name)
        assertEquals(target.id, parsed.id)
        assertEquals(target.host, parsed.host)
        assertEquals(target.port, parsed.port)
        assertTrue(parsed.pinRequired)
    }

    @Test
    fun missingNameAndPlatformAreOptional() {
        val target = mac.copy(name = "", platform = "")
        val parsed = TagCodec.parseUri(TagCodec.buildUri(target))
        assertNotNull(parsed)
        assertEquals("", parsed!!.name)
        assertEquals("", parsed.platform)
    }

    @Test
    fun nameIsTruncatedNotRejected() {
        val target = mac.copy(name = "A".repeat(70))
        val parsed = TagCodec.parseUri(TagCodec.buildUri(target))
        assertNotNull(parsed)
        assertEquals(64, parsed!!.name.length)
    }

    @Test
    fun overlongPayloadIsRejected() {
        // 正常写入方会省略名字；真收到超长 payload 就当垃圾数据
        val target = mac.copy(name = "名".repeat(200))
        assertNull(TagCodec.parseUri(TagCodec.buildUri(target)))
    }

    @Test
    fun rejectsForeignPayloads() {
        assertNull(TagCodec.parseUri(null))
        assertNull(TagCodec.parseUri(""))
        assertNull(TagCodec.parseUri("https://example.com/tap?v=1&id=3f2a9c81d4b7e065&h=192.168.1.2"))
        assertNull(TagCodec.parseUri("landrop://other?v=1&id=3f2a9c81d4b7e065&h=192.168.1.2&t=47823"))
        assertNull(TagCodec.parseUri("landrop://tap?v=9&id=3f2a9c81d4b7e065&h=192.168.1.2&t=47823"))
        assertNull(TagCodec.parseUri("landrop://tap?v=1&h=192.168.1.2&t=47823"))
        assertNull(TagCodec.parseUri("landrop://tap?v=1&id=zzz&h=192.168.1.2&t=47823"))
        assertNull(TagCodec.parseUri("landrop://tap?v=1&id=3f2a9c81d4b7e065&h=192.168.1.2&t=nope"))
        assertNull(TagCodec.parseUri("landrop://tap?v=1&id=3f2a9c81d4b7e065&h=192.168.1.2&t=70000"))
        assertNull(TagCodec.parseUri("landrop://tap?v=1&id=3f2a9c81d4b7e065&h=8.8.8.8&t=47823"))
    }

    @Test
    fun onlyPrivateHostsAreAccepted() {
        for (host in listOf("10.0.0.7", "172.16.3.9", "172.31.255.1", "192.168.0.2", "169.254.1.1", "100.100.1.1", "macbook.local", "[fe80::1]")) {
            assertTrue(host, TagCodec.isLanHost(host))
        }
        for (host in listOf("", "8.8.8.8", "172.32.0.1", "1.1.1.1", "example.com", "10.0.0", "10.0.0.256", "a.local.evil.com")) {
            assertFalse(host, TagCodec.isLanHost(host))
        }
    }

    @Test
    fun typicalPayloadFitsNtag213() {
        // 带 AAR + 名字也要能塞进 144 字节的 NTAG213
        assertTrue(TagCodec.ndefBytes(mac, withAar = true) <= 144)
        val chinese = mac.copy(name = "我的 Mac")
        assertTrue(TagCodec.ndefBytes(chinese, withAar = true) <= 144)
        // 省略名字一定要能塞下
        val long = mac.copy(name = "超长的设备名字".repeat(6))
        assertTrue(TagCodec.ndefBytes(long, withAar = false, includeName = false) <= 144)
    }

    @Test
    fun uriIsShortEnoughForRealTags() {
        val uri = TagCodec.buildUri(mac)
        assertTrue("uri=${uri.length}", uri.length < 160)
    }
}
