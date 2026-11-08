// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LanDrop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LanDrop", targets: ["LanDrop"])
    ],
    targets: [
        .executableTarget(
            name: "LanDrop",
            path: "Sources/LanDrop",
            resources: [.process("Resources")],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        )
    ]
)
