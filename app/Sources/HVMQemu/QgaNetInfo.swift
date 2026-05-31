// HVMQemu/QgaNetInfo.swift
// qemu-guest-agent `guest-network-get-interfaces` 封装 — 拿 guest 网卡 + IP 地址.
// 用途: GUI 详情页显示 guest IP (SSH/RDP 用) + hvm-dbg guest-netinfo. Linux/Windows guest 都支持.
// 前提: guest 内 qemu-ga 服务在跑 (Win 走 UTM Guest Tools, Linux apt install qemu-guest-agent).
// socket / NDJSON 通路复用 QgaSocket.swift.

import Foundation

public enum QgaNetInfo {

    public struct IPAddr: Sendable, Codable {
        public let address: String   // "192.168.64.7"
        public let type: String      // "ipv4" / "ipv6"
        public let prefix: Int?      // 网络前缀长度 (e.g. 24)
        public init(address: String, type: String, prefix: Int?) {
            self.address = address; self.type = type; self.prefix = prefix
        }
    }

    public struct Interface: Sendable, Codable {
        public let name: String              // "eth0" / "Ethernet"
        public let hardwareAddress: String?  // MAC
        public let ipAddresses: [IPAddr]
        public init(name: String, hardwareAddress: String?, ipAddresses: [IPAddr]) {
            self.name = name; self.hardwareAddress = hardwareAddress; self.ipAddresses = ipAddresses
        }
    }

    /// 拉 guest 全部网卡 + IP. 阻塞直到响应 / 超时.
    public static func interfaces(socketPath: String, timeoutSec: Int = 10) async throws -> [Interface] {
        let conn = try QgaSocket.connect(socketPath: socketPath)
        defer { conn.close() }
        let ret = try conn.call(
            execute: "guest-network-get-interfaces",
            deadline: Date().addingTimeInterval(TimeInterval(timeoutSec))
        )
        guard let arr = ret as? [[String: Any]] else {
            throw QgaError.execStartFailed(reason: "guest-network-get-interfaces 返回非数组: \(ret)")
        }
        return arr.compactMap { dict -> Interface? in
            guard let name = dict["name"] as? String else { return nil }
            let mac = dict["hardware-address"] as? String
            let ipsRaw = (dict["ip-addresses"] as? [[String: Any]]) ?? []
            let ips = ipsRaw.compactMap { ip -> IPAddr? in
                guard let addr = ip["ip-address"] as? String,
                      let type = ip["ip-address-type"] as? String else { return nil }
                return IPAddr(address: addr, type: type, prefix: ip["prefix"] as? Int)
            }
            return Interface(name: name, hardwareAddress: mac, ipAddresses: ips)
        }
    }

    /// 挑"主 IPv4" 给 GUI 一行展示: 跳过 loopback (127.) / link-local (169.254.) , 取第一个常规 IPv4.
    /// 没有则返 nil (guest 没配网 / 还没拿到 DHCP).
    public static func primaryIPv4(_ ifaces: [Interface]) -> String? {
        for iface in ifaces {
            for ip in iface.ipAddresses where ip.type == "ipv4" {
                if ip.address.hasPrefix("127.") || ip.address.hasPrefix("169.254.") { continue }
                return ip.address
            }
        }
        return nil
    }
}
