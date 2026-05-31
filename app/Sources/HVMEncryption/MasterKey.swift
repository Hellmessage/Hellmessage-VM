// HVMEncryption/MasterKey.swift
// 32 字节 master KEK 值类型. 随机生成 + 长度校验 + 调用方读 bytes.
//
// 安全: 内部走 SecureBytes (mlock 防 swap + memset_s 销毁前清零); 32 字节强校验;
// 不 Codable / 不 print / 不 log.

import Foundation
import Security
import HVMCore

/// 32 字节 (256 bit) AES master KEK. 内部 mlock 防 swap.
public struct MasterKey: Sendable {
    /// 标准长度 = 256 bit AES key
    public static let lengthBytes = 32

    /// mlock + memset_s 内存. SecureBytes 是 class → 多份 MasterKey 共享同一 buffer
    /// (deinit 在最后一份释放时清零).
    private let storage: SecureBytes

    /// 用现成 32 字节 Data 包. 长度不对抛 .invalidKeyLength. 拷贝进 mlocked SecureBytes.
    public init(_ data: Data) throws {
        guard data.count == Self.lengthBytes else {
            throw HVMError.encryption(.invalidKeyLength(got: data.count, expected: Self.lengthBytes))
        }
        self.storage = try SecureBytes(copying: data)
    }

    /// 内部用: 直接给 SecureBytes 包, 不走 Data 中转 (避免拷贝痕迹).
    init(secure: SecureBytes) throws {
        guard secure.count == Self.lengthBytes else {
            throw HVMError.encryption(.invalidKeyLength(got: secure.count, expected: Self.lengthBytes))
        }
        self.storage = secure
    }

    /// 生成 cryptographically secure 32 字节 random KEK (走 SecRandomCopyBytes).
    public static func random() throws -> MasterKey {
        let secure = try SecureBytes(count: lengthBytes)
        let status = secure.withMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return Int32(SecRandomCopyBytes(kSecRandomDefault, lengthBytes, base))
        }
        guard status == errSecSuccess else {
            throw HVMError.encryption(.randomGenerationFailed(status: status))
        }
        return try MasterKey(secure: secure)
    }

    /// 把 bytes 暴露给加密 API (HKDF / qemu-img secret) 用. 调用方自负不要复制走.
    public func withBytes<R>(_ closure: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withBytes(closure)
    }

    /// 拷贝出 Data 给上游. 注: 这一拷贝离开 mlock 保护进入普通堆.
    public func dataCopy() -> Data {
        storage.withBytes { Data($0) }
    }

    /// base64 输出 (qemu-img --object secret data=base64 用; HVM 内部不用).
    public func base64String() -> String {
        storage.withBytes { Data($0).base64EncodedString() }
    }
}
