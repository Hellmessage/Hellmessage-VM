// HVMUtils/Hashing.swift
// 跨模块共用的 hash 工具.

import Foundation
import CryptoKit

public enum Hashing {

    /// SHA256 → 64 字符小写 hex string. 用于截图去重 / 文件指纹比对.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
