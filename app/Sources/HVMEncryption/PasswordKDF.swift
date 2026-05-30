// HVMEncryption/PasswordKDF.swift
// 用户密码 → master KEK 派生. PBKDF2-SHA256, 跨机器 portable 的核心.
//
// 创建加密 VM 时生成 16B random salt 写明文 routing JSON; 启动时读回 salt + iter 重新
// PBKDF2 派生. 跨机器拷 .hvmz + routing JSON + 输同密码 → 派生同 master KEK.
//
// 选 PBKDF2-SHA256 (非 argon2id): Apple CommonCrypto 内置无第三方依赖; 600k iter 是
// 2024 OWASP 推荐值. routing JSON 留 kdf_algo 字段为未来切 argon2id 留余地. 派生 ~80-150ms.

import Foundation
import CommonCrypto
import Security
import HVMCore

public enum PasswordKDF {
    /// 默认 PBKDF2 iteration. 写到 routing JSON 的 kdf_iterations 字段.
    /// 2024 OWASP 推荐 PBKDF2-SHA256 ≥ 600k.
    public static let defaultIterations: UInt32 = 600_000

    /// salt 标准长度. 16 字节足够防 rainbow table (2^128 唯一性).
    public static let saltLengthBytes = 16

    /// master KEK 标准长度 = 256 bit AES key. 与 MasterKey.lengthBytes 对齐.
    public static let derivedKeyLengthBytes = 32

    /// 安全下限 — 防参数手抖错传 (例如 kdf_iterations=10 这种灾难).
    public static let minSafeIterations: UInt32 = 100_000

    /// 生成 16 字节 cryptographically secure random salt (走 SecRandomCopyBytes).
    public static func generateSalt() throws -> Data {
        var salt = Data(count: saltLengthBytes)
        let status = salt.withUnsafeMutableBytes { rawPtr -> Int32 in
            guard let base = rawPtr.baseAddress else { return errSecParam }
            return Int32(SecRandomCopyBytes(kSecRandomDefault, saltLengthBytes, base))
        }
        guard status == errSecSuccess else {
            throw HVMError.encryption(.randomGenerationFailed(status: status))
        }
        return salt
    }

    /// PBKDF2-SHA256 派生 master KEK. 返回 32 字节 MasterKey.
    /// - Parameter password: 用户密码 UTF-8. 空字符串拒绝.
    /// - Parameter salt: routing JSON 写入的 16 字节 random.
    /// - Parameter iterations: 默认 600k. 低于 minSafeIterations 拒绝.
    public static func deriveMasterKey(password: String,
                                       salt: Data,
                                       iterations: UInt32 = defaultIterations) throws -> MasterKey {
        guard !password.isEmpty else {
            throw HVMError.encryption(.kdfFailed(reason: "密码不能为空"))
        }
        guard !salt.isEmpty else {
            throw HVMError.encryption(.kdfFailed(reason: "salt 不能为空"))
        }
        guard iterations >= minSafeIterations else {
            throw HVMError.encryption(.kdfFailed(reason: "iterations=\(iterations) 低于安全下限 \(minSafeIterations)"))
        }

        var derived = Data(count: derivedKeyLengthBytes)
        let pwdBytes = Array(password.utf8)

        let ccStatus: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                guard let saltBase = saltPtr.bindMemory(to: UInt8.self).baseAddress,
                      let derivedBase = derivedPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdBytes, pwdBytes.count,
                    saltBase, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedBase, derivedKeyLengthBytes
                )
            }
        }
        guard ccStatus == 0 else {
            throw HVMError.encryption(.kdfFailed(reason: "CCKeyDerivationPBKDF status=\(ccStatus)"))
        }
        return try MasterKey(derived)
    }
}
