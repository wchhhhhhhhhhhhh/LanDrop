import Foundation
import Darwin

/// UDP 广播发现：probe / announce
final class Discovery {
    static let udpPort: UInt16 = 47824

    private var fd: Int32 = -1
    private var running = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "landrop.discovery")
    private let config: Config
    private let serverPort: () -> Int

    /// (peer, 来源 IP)
    var onAnnounce: ((Beacon, String) -> Void)?

    init(config: Config, serverPort: @escaping () -> Int) {
        self.config = config
        self.serverPort = serverPort
    }

    // MARK: 生命周期

    func start() {
        guard !running else { return }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Discovery.udpPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            fd = -1
            return
        }

        running = true
        queue.async { [weak self] in self?.receiveLoop() }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 15.0)
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        timer = t
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: 发包

    private var myBeacon: Beacon {
        Beacon(type: "probe",
               id: config.deviceID,
               name: config.name,
               platform: "macos",
               port: serverPort(),
               pinRequired: config.pinEnabled)
    }

    func probe() {
        guard fd >= 0 else { return }
        let payload = (try? JSONEncoder().encode(myBeacon)) ?? Data()
        for target in Net.broadcastTargets() {
            send(payload, to: target)
        }
    }

    private func send(_ payload: Data, to host: String) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Discovery.udpPort.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return }
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                payload.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: 收包

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { p -> Int in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &len)
                }
            }
            guard n > 0 else {
                if n < 0 && errno == EINTR { continue }
                if !running { break }
                usleep(200_000)
                continue
            }

            let data = Data(bytes: buffer, count: n)
            guard let beacon = try? JSONDecoder().decode(Beacon.self, from: data),
                  beacon.app == "landrop", !beacon.id.isEmpty, beacon.id != config.deviceID else { continue }

            let sin = addr.sin_addr
            let ip: String = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        return String(cString: host)
                    }
                    return String(cString: inet_ntoa(sin))
                }
            }

            if beacon.type == "probe" {
                // 会 probe 说明对方在线：直接登记，不必等它发 announce
                let b = beacon
                DispatchQueue.main.async { [weak self] in
                    self?.onAnnounce?(b, ip)
                }
                // 同时单播回自己的信息，让对方也能立刻看到我
                var reply = myBeacon
                reply.type = "announce"
                if let payload = try? JSONEncoder().encode(reply) {
                    send(payload, to: ip)
                }
            } else if beacon.type == "announce" {
                let b = beacon
                DispatchQueue.main.async { [weak self] in
                    self?.onAnnounce?(b, ip)
                }
            }
        }
    }
}
