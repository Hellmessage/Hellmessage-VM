// HVMNet/IPResolver.swift
// 通过 host 的 ARP 表反查 guest IP. VZ 不暴露 guest 内部 IP, 又不能装 guest agent (CLAUDE.md
// 禁止), 所以走 host 侧 ARP 是最朴素的零依赖方案:
//
//   `arp -an` 输出形如:
//     ? (192.168.64.5) at 1a:2b:3c:4d:5e:6f on bridge100 ifscope [ethernet]
//
// 5s LRU cache 避免菜单频繁弹出导致每次都 fork arp 进程.
//
// 局限:
//   - guest 启动后必须跟 host 通过任意 traffic 才会出现在 ARP 表 (DHCP / icmp / ssh 之类)
//   - guest 关机后 ARP entry 仍会残留几分钟 (kernel 缓存)
//   - MAC 大小写 / 前导零问题: arp 输出可能是 "1a:2b:3:4:5:6", 比对时双方都规范化
//
// 桥接 (M4) 模式下也走同样的查法, 因为 host 跟物理 LAN 上 guest 也走 ARP.

import Foundation

public enum IPResolver {
    /// 5 秒缓存, 避免菜单频繁弹起每次 fork arp.
    private static let cacheTTL: TimeInterval = 5.0
    /// 由 lock 串行保护, 用 nonisolated(unsafe) 跳过 Swift 6 全局可变状态检查
    nonisolated(unsafe) private static var cache: (timestamp: Date, table: [String: String])?
    private static let lock = NSLock()

    /// 查给定 MAC 对应的 IPv4 地址. 没找到返回 nil.
    public static func ipForMAC(_ mac: String) -> String? {
        let needle = normalize(mac)
        guard !needle.isEmpty else { return nil }
        return arpTable()[needle]
    }

    /// 强制刷新 (跑 arp 命令). 给测试 / 用户显式刷新用.
    public static func invalidateCache() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
    }

    // MARK: - 私有

    /// 当前 ARP 表 (MAC → IP), 5s 缓存.
    private static func arpTable() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, Date().timeIntervalSince(c.timestamp) < cacheTTL {
            return c.table
        }
        let table = parseARP(runARP())
        cache = (Date(), table)
        return table
    }

    private static func runARP() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()  // 吞掉 stderr
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// arp -an 行格式: "? (192.168.64.5) at 1a:2b:3c:4d:5e:6f on bridge100 ifscope [ethernet]"
    /// 也可能是 "(incomplete)" entry, 跳过.
    private static func parseARP(_ output: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in output.split(separator: "\n") {
            // 抓 (IP) 和 MAC
            guard let ipStart = line.firstIndex(of: "("),
                  let ipEnd = line.firstIndex(of: ")"),
                  ipStart < ipEnd else { continue }
            let ip = String(line[line.index(after: ipStart)..<ipEnd])
            // " at <MAC> on " 之间是 MAC; "(incomplete)" 跳过
            guard let atRange = line.range(of: " at "),
                  let onRange = line.range(of: " on ", range: atRange.upperBound..<line.endIndex) else { continue }
            let macRaw = String(line[atRange.upperBound..<onRange.lowerBound])
            if macRaw.contains("incomplete") { continue }
            let mac = normalize(macRaw)
            guard !mac.isEmpty else { continue }
            // 同一 MAC 多 IP 时取第一个 (NAT 一般不会出现)
            if table[mac] == nil { table[mac] = ip }
        }
        return table
    }

    /// MAC 规范化: 小写 + 每段补零到 2 位 ("1a:2b:3:4:5:6" → "1a:2b:03:04:05:06")
    private static func normalize(_ mac: String) -> String {
        let parts = mac.lowercased().split(separator: ":")
        guard parts.count == 6 else { return "" }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }
}
