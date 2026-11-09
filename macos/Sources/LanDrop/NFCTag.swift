import Foundation

/// NFC 贴纸载荷：与 Android 端 `nfc/TagCodec.kt` 必须逐字节一致。
///
/// 格式（v1）：
/// `landrop://tap?v=1&id=<16hex>&n=<名字>&p=<平台>&h=<host>&t=<port>[&k=1]`
/// 所有值都是 percent-encoding 后的 UTF-8。
enum LandropTag {
    static let scheme = "landrop"
    static let host = "tap"
    static let version = 1

    struct Target: Equatable {
        var id: String
        var name: String
        var platform: String
        var host: String
        var port: Int
        var pinRequired: Bool

        var endpoint: String { "\(host):\(port)" }
    }

    static func uri(_ target: Target, includeName: Bool = true) -> String {
        var out = "\(scheme)://\(host)?v=\(version)"
        out += "&id=\(target.id.lowercased())"
        if includeName {
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { out += "&n=\(percent(name))" }
        }
        let platform = target.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !platform.isEmpty { out += "&p=\(percent(platform))" }
        out += "&h=\(target.host.trimmingCharacters(in: .whitespaces))"
        out += "&t=\(target.port)"
        if target.pinRequired { out += "&k=1" }
        return out
    }

    /// 估算 NDEF 占用：URI 记录 5 字节头 + 载荷 + TLV 2 字节；AAR 再多 37 字节。
    static func ndefBytes(_ target: Target, withAar: Bool, includeName: Bool = true) -> Int {
        var total = 5 + uri(target, includeName: includeName).utf8.count + 2
        if withAar { total += 37 }
        return total
    }

    /// 与 Android 端相同的私网判断：贴纸只能指向局域网地址
    static func isLanHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 253 else { return false }

        if h.hasPrefix("["), h.hasSuffix("]"), h.count > 2 {
            return isLanV6(String(h.dropFirst().dropLast()))
        }

        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) else {
                return false
            }
            let nums = parts.compactMap { Int($0) }
            guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return false }
            let a = nums[0], b = nums[1]
            return a == 10
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168)
                || (a == 169 && b == 254)
                || (a == 100 && (64...127).contains(b))
        }

        let lower = h.lowercased()
        return lower.hasSuffix(".local") && lower.count > 6
    }

    private static func isLanV6(_ raw: String) -> Bool {
        let h = raw.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard h.contains(":") else { return false }
        return h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
            || h.hasPrefix("fc") || h.hasPrefix("fd")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func percent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
