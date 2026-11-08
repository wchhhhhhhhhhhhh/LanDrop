package com.landrop.android.net

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

object NetInfo {

    /** 局域网 IPv4 地址（优先 wlan 网卡） */
    fun localIp(): String {
        val candidates = mutableListOf<Pair<String, String>>() // ifname to ip
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        candidates.add(iface.name to addr.hostAddress.orEmpty())
                    }
                }
            }
        } catch (_: Exception) {
        }
        candidates.firstOrNull { it.first.startsWith("wlan") }?.let { return it.second }
        candidates.firstOrNull { it.first.startsWith("en") }?.let { return it.second }
        return candidates.firstOrNull()?.second ?: "127.0.0.1"
    }

    fun broadcastAddresses(): List<InetAddress> {
        val out = linkedSetOf<InetAddress>()
        out.add(InetAddress.getByName("255.255.255.255"))
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                for (ia in iface.interfaceAddresses) {
                    ia.broadcast?.let { out.add(it) }
                }
            }
        } catch (_: Exception) {
        }
        return out.toList()
    }
}
