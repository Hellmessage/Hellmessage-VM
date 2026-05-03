// HVMEncryption/MasterKey.swift
// 32 字节 master KEK 值类型. 提供随机生成 + 长度校验 + 调用方读 bytes.
//
// 安全注: Swift Data 是 COW 普通堆内存, 不强 secure-wipe (mlock / memset_s 等增强留待后续 PR;
// 详见 docs/v3/ENCRYPTION.md "未决事项"). 本类型仅做最小安全约定:
//   - 32 字节强校验 (256 bit AES key 标准长度)
//   - 不 Codable / 不 print debugDescription / 不 log
//   - 调用方自负: 用完后尽快脱离作用域, 让 ARC 释放底层 buffer
//
// 不做:
//   - mlock 防交换 (留 PR 后续优化)
//   - memset_s 销毁前清零 (Swift 不暴露 deinit hook for Data)
//   - Hardware Secure Enclave 派生 (key 由 Keychain 守, Enclave 间接保护)

import Foundation
import Security
import HVMCore

/// 32 字节 (256 bit) AES master KEK. 持有期间内 bytes 只读.
public struct MasterKey: Sendable {
    /// 标准长度 = 256 bit AES key
    public static let lengthBytes = 32

    private let bytes: Data

    /// 用现成 32 字节 Data 包. 长度不对抛 .invalidKeyLength.
    public init(_ data: Data) throws {
        guard data.count == Self.lengthBytes else {
            throw HVMError.encryption(.invalidKeyLength(got: data.count, expected: Self.lengthBytes))
        }
        self.bytes = data
    }

    /// 生成 cryptographically secure 32 字节 random KEK.
    /// 走 SecRandomCopyBytes (Apple 官方 CSPRNG, 内核 /dev/urandom 等价但带 Secure Enclave 接口).
    public static func random() throws -> MasterKey {
        var buf = Data(count: lengthBytes)
        let status = buf.withUnsafeMutableBytes { rawPtr -> Int32 in
            guard let base = rawPtr.baseAddress else { return errSecParam }
            return Int32(SecRandomCopyBytes(kSecRandomDefault, lengthBytes, base))
        }
        guard status == errSecSuccess else {
            throw HVMError.encryption(.randomGenerationFailed(status: status))
        }
        return try MasterKey(buf)
    }

    /// 把 bytes 暴露给加密 API (HKDF / hdiutil stdin / qemu-img secret) 用.
    /// 注: closure 期间不持续生命; 调用方自负不要复制走.
    public func withBytes<R>(_ closure: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(closure)
    }

    /// 拷贝出 Data 给上游 (Keychain SecItemAdd 需要 Data 形式 kSecValueData).
    /// 注: 这一拷贝会进入 Keychain 内部存储, 上游不持有 ARC 拷贝.
    public func dataCopy() -> Data {
        bytes
    }

    /// base64 输出 (qemu-img --object secret data=base64 用; HVM 内部不用).
    public func base64String() -> String {
        bytes.base64EncodedString()
    }
}
