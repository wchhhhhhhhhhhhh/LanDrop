import Foundation

/// 无界面模式：`LanDrop --serve [--port 47823] [--dir ~/Downloads/LanDrop] [--pin 123456] [--name 主机名]`
/// 方便在服务器/CI 上跑，也用于协议自测。
enum CLI {
    static func run(arguments: [String]) {
        setvbuf(stdout, nil, _IONBF, 0)
        var args = arguments.dropFirst()
        var port = Config.shared.port
        var dir = Config.shared.inbox
        var pinOverride: String?
        var nameOverride: String?
        var idOverride: String?
        var noPin = false

        while let arg = args.first {
            args = args.dropFirst()
            switch arg {
            case "--port":
                if let v = args.first, let p = Int(v) { port = p; args = args.dropFirst() }
            case "--dir":
                if let v = args.first { dir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true); args = args.dropFirst() }
            case "--pin":
                if let v = args.first { pinOverride = v; args = args.dropFirst() }
            case "--no-pin":
                noPin = true
            case "--id":
                if let v = args.first { idOverride = v; args = args.dropFirst() }
            case "--name":
                if let v = args.first { nameOverride = v; args = args.dropFirst() }
            case "--help", "-h":
                print("""
                LanDrop 局域网传输（macOS）

                用法:
                  LanDrop                 启动图形界面
                  LanDrop --serve         无界面服务端（做接收端 / 测试用）
                    --port <端口>         默认 47823
                    --dir  <收件箱目录>    默认 ~/Downloads/LanDrop
                    --pin  <6位配对码>     仅本次生效
                    --name <设备名>
                """)
                exit(0)
            default:
                break
            }
        }

        let config = Config.shared
        if let nameOverride { config.name = nameOverride }
        if let idOverride { config.overrideDeviceID(idOverride) }
        if let pinOverride { config.pin = pinOverride; config.pinEnabled = true }
        if noPin { config.pinEnabled = false }
        config.inbox = dir

        let store = FileStore(inbox: dir)
        let server = HTTPServer(store: store, config: config)

        guard let bound = server.start(preferredPort: port) else {
            FileHandle.standardError.write(Data("端口 \(port) 无法监听\n".utf8))
            exit(1)
        }

        print("LanDrop CLI 已启动")
        print("  设备名   : \(config.name)")
        print("  设备 ID  : \(config.deviceID)")
        print("  地址     : http://\(Net.primaryIP()):\(bound)")
        print("  收件箱   : \(dir.path)")
        if config.pinEnabled { print("  配对码   : \(config.pin)") }
        print("  发现     : UDP \(Discovery.udpPort)")
        print("按 Ctrl-C 退出。")

        let discovery = Discovery(config: config, serverPort: { bound })
        discovery.onAnnounce = { beacon, ip in
            print("发现设备: \(beacon.name) [\(beacon.platform)] \(ip):\(beacon.port)")
        }
        discovery.start()
        discovery.probe()

        withExtendedLifetime((store, server, discovery)) {
            RunLoop.main.run()
        }
    }
}
