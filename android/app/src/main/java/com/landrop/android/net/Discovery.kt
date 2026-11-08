package com.landrop.android.net

import android.util.Log
import com.landrop.android.model.Peer
import com.landrop.android.model.Platform
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.Timer
import java.util.TimerTask
import org.json.JSONObject

/** UDP 广播发现：probe / announce */
class Discovery(
    private val selfId: String,
    private val buildBeacon: () -> JSONObject,
    private val onPeer: (Peer) -> Unit
) {
    private var socket: DatagramSocket? = null
    private var timer: Timer? = null
    @Volatile private var running = false

    val isRunning: Boolean get() = running

    fun start() {
        if (running) return
        val s = DatagramSocket(null)
        s.reuseAddress = true
        s.broadcast = true
        s.bind(InetSocketAddress(HttpServer.UDP_PORT))
        socket = s
        running = true
        Thread({ loop(s) }, "landrop-udp").apply { isDaemon = true }.start()
        timer = Timer("landrop-probe", true).apply {
            scheduleAtFixedRate(object : TimerTask() {
                override fun run() = probe()
            }, 300, 15_000)
        }
    }

    fun stop() {
        running = false
        timer?.cancel()
        timer = null
        runCatching { socket?.close() }
        socket = null
    }

    fun probe() {
        val s = socket ?: return
        val payload = buildBeacon().also { it.put("type", "probe") }.toString().toByteArray()
        for (addr in NetInfo.broadcastAddresses()) {
            try {
                s.send(DatagramPacket(payload, payload.size, addr, HttpServer.UDP_PORT))
            } catch (e: Exception) {
                // 部分网卡不允许广播
            }
        }
    }

    private fun loop(s: DatagramSocket) {
        val buffer = ByteArray(2048)
        while (running) {
            try {
                val packet = DatagramPacket(buffer, buffer.size)
                s.receive(packet)
                val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                val json = runCatching { JSONObject(text) }.getOrNull() ?: continue
                if (json.optString("app") != "landrop") continue
                val id = json.optString("id")
                if (id.isEmpty() || id == selfId) continue
                val ip = packet.address.hostAddress ?: continue
                when (json.optString("type")) {
                    "probe" -> {
                        // 会 probe 说明对方在线，直接登记
                        val peer = Peer(
                            id = id,
                            name = json.optString("name", "未知设备"),
                            platform = Platform.from(json.optString("platform")),
                            host = ip,
                            port = json.optInt("port", HttpServer.TCP_PORT),
                            pinRequired = json.optBoolean("pin_required", false)
                        )
                        Log.i("LanDrop", "peer(probe) ${peer.name} ${peer.host}:${peer.port} pin=${peer.pinRequired}")
                        onPeer(peer)
                        val reply = buildBeacon().also { it.put("type", "announce") }
                            .toString().toByteArray()
                        runCatching {
                            s.send(DatagramPacket(reply, reply.size, packet.address, HttpServer.UDP_PORT))
                        }
                    }
                    "announce" -> {
                        val peer = Peer(
                            id = id,
                            name = json.optString("name", "未知设备"),
                            platform = Platform.from(json.optString("platform")),
                            host = ip,
                            port = json.optInt("port", HttpServer.TCP_PORT),
                            pinRequired = json.optBoolean("pin_required", false)
                        )
                        Log.i("LanDrop", "peer ${peer.name} ${peer.host}:${peer.port} pin=${peer.pinRequired}")
                        onPeer(peer)
                    }
                }
            } catch (e: Exception) {
                if (!running) break
                Log.w("LanDrop", "udp: ${e.message}")
            }
        }
    }

    companion object {
        @Suppress("unused")
        private fun addr(ip: String) = InetAddress.getByName(ip)
    }
}
