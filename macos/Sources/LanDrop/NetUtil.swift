import Foundation
import Darwin

/// 网卡地址工具
enum Net {
    struct Addr {
        let ifname: String
        let ip: String
        let broadcast: String?
        let isLoopback: Bool
    }

    static func addresses() -> [Addr] {
        var result: [Addr] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            let flags = Int32(p.pointee.ifa_flags)
            let isLoop = (flags & IFF_LOOPBACK) != 0

            var bcast: String?
            if (flags & IFF_BROADCAST) != 0, let dst = p.pointee.ifa_dstaddr {
                var bhost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(dst, socklen_t(dst.pointee.sa_len),
                               &bhost, socklen_t(bhost.count), nil, 0, NI_NUMERICHOST) == 0 {
                    bcast = String(cString: bhost)
                }
            }
            result.append(Addr(ifname: String(cString: p.pointee.ifa_name),
                               ip: ip, broadcast: bcast, isLoopback: isLoop))
        }
        return result
    }

    /// 局域网主 IP（优先 en0 等非虚拟网卡）
    static func primaryIP() -> String {
        let all = addresses().filter { !$0.isLoopback && !$0.ip.hasPrefix("169.254") }
        let preferred = all.first { $0.ifname == "en0" }
            ?? all.first { $0.ifname.hasPrefix("en") }
            ?? all.first
        return preferred?.ip ?? "127.0.0.1"
    }

    static func broadcastTargets() -> [String] {
        var set = Set<String>(["255.255.255.255"])
        for a in addresses() where !a.isLoopback {
            if let b = a.broadcast { set.insert(b) }
        }
        return Array(set)
    }
}
