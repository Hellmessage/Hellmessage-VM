// HVMEncryption/RoutingMetadata.swift
// 加密 VM 的路由元数据 — 明文 JSON 文件, **不**在加密内.
// 跨机器 portable 入口: 目标机读 routing JSON 拿 KDF 参数 + scheme,
// 用户输密码 → PBKDF2(password, salt) → master KEK → 解锁 VM.
//
// 设计稿 docs/v3/ENCRYPTION.md v2.3.
//
// 文件位置:
//   - VZ-sparsebundle: <parent>/<name>.hvmz.encryption.json (sparsebundle 同级)
//   - QEMU-perfile:    <bundle>.hvmz/meta/encryption.json (bundle 内)
//
// 字段命名走 snake_case (跟设计稿 + 业界惯例对齐, 也方便用户手动编辑诊断).
// schemaVersion 是 routing JSON 自己的版本, **不是** VMConfig schemaVersion.

import Foundation
import HVMBundle
import HVMCore

public struct RoutingMetadata: Sendable, Equatable, Codable {
    /// routing JSON 自己的 schema 版本 (与 VMConfig.schemaVersion 不同维度).
    /// v1: 初稿 (kek_source / keychain_item) — 已废
    /// v2: 加 kdf_* 字段 (强制密码 + 跨机器 portable; v2.2)
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var vmId: UUID
    public var scheme: EncryptionSpec.EncryptionScheme
    public var displayName: String

    // KDF 参数 (跨机器派生 master KEK 必备)
    public var kdfAlgo: String                  // "pbkdf2-sha256" — 未来切 argon2id 升 v3
    public var kdfIterations: UInt32
    public var kdfSalt: Data                    // 16 字节 random; JSON 编 base64 (Data 默认)
    public var kdfKeylen: Int                   // 32 (256 bit)

    /// QEMU 路径附加 (诊断用): 哪些文件被加密了.
    /// VZ 路径 nil (整 sparsebundle 加密, 不需要分项列).
    public var encryptedPaths: [String]?

    /// QEMU 加密路径默认列出的文件.
    public static let qemuEncryptedPaths: [String] = [
        "config.yaml.enc",
        "disks/os.qcow2",
        "disks/data-*.qcow2",
        "nvram/efi-vars.qcow2",
        "tpm/permall",
    ]

    public init(vmId: UUID,
                scheme: EncryptionSpec.EncryptionScheme,
                displayName: String,
                kdfSalt: Data,
                kdfIterations: UInt32 = PasswordKDF.defaultIterations) {
        self.schemaVersion = Self.currentSchemaVersion
        self.vmId = vmId
        self.scheme = scheme
        self.displayName = displayName
        self.kdfAlgo = "pbkdf2-sha256"
        self.kdfIterations = kdfIterations
        self.kdfSalt = kdfSalt
        self.kdfKeylen = PasswordKDF.derivedKeyLengthBytes
        self.encryptedPaths = (scheme == .qemuPerfile) ? Self.qemuEncryptedPaths : nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case vmId           = "vm_id"
        case scheme
        case displayName    = "display_name"
        case kdfAlgo        = "kdf_algo"
        case kdfIterations  = "kdf_iterations"
        case kdfSalt        = "kdf_salt"
        case kdfKeylen      = "kdf_keylen"
        case encryptedPaths = "encrypted_paths"
    }
}

// MARK: - Routing JSON 文件位置 + I/O

public enum RoutingJSON {
    /// VZ 路径 routing JSON 位置: 与 sparsebundle 同级.
    /// 例: <parent>/Foo.hvmz.sparsebundle → <parent>/Foo.hvmz.encryption.json
    public static func locationForSparsebundle(_ sparsebundleURL: URL) -> URL {
        let stem = sparsebundleURL.deletingPathExtension()  // .hvmz
        return stem.appendingPathExtension("encryption.json")
    }

    /// QEMU 路径 routing JSON 位置: bundle 内 meta/encryption.json
    public static func locationForQemuBundle(_ bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("meta", isDirectory: true)
                 .appendingPathComponent("encryption.json")
    }

    /// 写入 routing JSON (atomic, snake_case).
    public static func write(_ meta: RoutingMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dataEncodingStrategy = .base64

        let data: Data
        do {
            data = try encoder.encode(meta)
        } catch {
            throw HVMError.encryption(.parseFailed(reason: "routing JSON encode: \(error)"))
        }

        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tmp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw HVMError.bundle(.writeFailed(reason: "\(error)", path: url.path))
        }
    }

    /// 读 routing JSON. 文件不存在 / 解析失败抛对应错.
    public static func read(from url: URL) throws -> RoutingMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HVMError.bundle(.notFound(path: url.path))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "\(error)", path: url.path))
        }
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        do {
            return try decoder.decode(RoutingMetadata.self, from: data)
        } catch {
            throw HVMError.encryption(.parseFailed(reason: "routing JSON decode: \(error)"))
        }
    }
}
