// HVMNet/MACAddress.swift
// MAC 地址生成与校验. 始终使用 locally-administered 前缀 (第一字节低两位 = xx10)
// 详见 docs/NETWORK.md "MAC 地址"

import Foundation
import HVMCore

public enum MACAddressGenerator {
    /// 生成一个随机的 locally-administered MAC, 格式 "02:xx:xx:xx:xx:xx" 小写冒号分隔
    public static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        // 第一字节低四位中 U/L 位置 1 (locally administered), I/G 位置 0 (unicast)
        // 结果 pattern: xxxxxx10
        bytes[0] = (UInt8.random(in: 0...0xFF) & 0xFC) | 0x02
        for i in 1..<6 {
            bytes[i] = UInt8.random(in: 0...0xFF)
        }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// 校验 MAC 格式并确认是 locally-administered
    public static func validate(_ mac: String) throws {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else {
            throw HVMError.net(.macInvalid(mac))
        }
        var bytes = [UInt8]()
        for p in parts {
            guard p.count == 2, let v = UInt8(p, radix: 16) else {
                throw HVMError.net(.macInvalid(mac))
            }
            bytes.append(v)
        }
        // 第一字节的 U/L 位 (bit 1 of byte 0, 从低位数) 必须为 1
        guard (bytes[0] & 0x02) != 0 else {
            throw HVMError.net(.macNotLocallyAdministered(mac))
        }
        // 多播位 (bit 0 of byte 0) 必须为 0
        guard (bytes[0] & 0x01) == 0 else {
            throw HVMError.net(.macInvalid(mac))
        }
    }
}
