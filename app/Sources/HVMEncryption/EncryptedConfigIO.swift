// HVMEncryption/EncryptedConfigIO.swift
// QEMU 路径加密 VM 的 config.yaml in-place 加密. 设计稿 docs/v3/ENCRYPTION.md v2.2.
//
// 文件名: <bundle>/config.yaml.enc (与明文 config.yaml 互斥, 同 bundle 不能同时存在)
//
// 落盘格式 (二进制):
//   [0..3]   magic = "HENC" (4 bytes, 'H' 'E' 'N' 'C' = 0x48 0x45 0x4E 0x43)
//   [4]      format version = 0x01 (未来切 ChaCha20-Poly1305 / 加 AAD 等升 v2)
//   [5..7]   reserved = [0, 0, 0]
//   [8..]    AES.GCM.SealedBox.combined (12-byte nonce + ciphertext + 16-byte auth tag)
//
// 8 字节头部对齐, 让用户用 `head -c 8` / `xxd | head -1` 一眼能识别 HVM 加密 config.
//
// 加密流程:
//   1. config -> YAMLEncoder -> yaml string -> utf8 bytes (plaintext)
//   2. AES-256-GCM seal with config-key (random 12-byte nonce, output combined)
//   3. magic + version + reserved + combined -> atomic write to config.yaml.enc
//
// 解密流程:
//   1. read config.yaml.enc
//   2. 校验 magic + version
//   3. AES.GCM.SealedBox(combined: rest) -> AES.GCM.open(sealed, using: key)
//   4. plaintext bytes -> utf8 yaml string -> YAMLDecoder -> VMConfig
//   5. validate
//
// 错误处理:
//   - magic 不对 / version 不识别 / combined 长度不够 -> .parseFailed
//   - AES.GCM.open 失败 (auth tag 验证失败) -> .wrongPassword (密码错或文件被改)
//   - YAML 解析失败 -> .bundle(.parseFailed) (理论上密码对不会触发, 防御兜底)

import Foundation
import CryptoKit
import HVMBundle
import HVMCore
import Yams

public enum EncryptedConfigIO {
    /// 加密 config 文件名. 与 BundleLayout.configFileName ("config.yaml") 互斥.
    public static let configEncFileName = "config.yaml.enc"

    /// 4 字节 magic = ASCII "HENC" (HVM Encrypted Config)
    private static let magic: [UInt8] = [0x48, 0x45, 0x4E, 0x43]

    /// 当前 format version. 仅修改 ciphersuite (例 GCM → ChaCha20-Poly1305) 时 bump.
    private static let formatVersion: UInt8 = 0x01

    /// magic(4) + version(1) + reserved(3) = 8 字节
    private static let headerLength = 8

    public static func configEncURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(configEncFileName)
    }

    /// 检查 bundle 是否走加密 config 路径 (= config.yaml.enc 存在).
    /// 用于 EncryptedBundleIO 路由层判定 (PR-7 之后用).
    public static func isEncrypted(at bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: configEncURL(bundleURL).path)
    }

    // MARK: - save

    /// AES-GCM 加密 config 写到 <bundle>/config.yaml.enc, atomic. 走 .yaml.enc.tmp 中转.
    public static func save(config: VMConfig,
                             to bundleURL: URL,
                             key: SymmetricKey) throws {
        try config.validate()

        // 1. yaml encode (与 BundleIO.save 同款选项, 保持 round-trip 字节稳定)
        let encoder = YAMLEncoder()
        encoder.options.indent = 2
        encoder.options.sortKeys = true
        encoder.options.allowUnicode = true

        let yamlString: String
        do {
            yamlString = try encoder.encode(config)
        } catch {
            throw HVMError.bundle(.writeFailed(
                reason: "yaml encode (encrypted): \(error)",
                path: configEncURL(bundleURL).path
            ))
        }
        guard let plaintext = yamlString.data(using: .utf8) else {
            throw HVMError.bundle(.writeFailed(
                reason: "utf8 encoding 失败 (encrypted)",
                path: configEncURL(bundleURL).path
            ))
        }

        // 2. AES-256-GCM seal. CryptoKit 自动生成 12 字节 random nonce.
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw HVMError.encryption(.parseFailed(reason: "AES.GCM.seal: \(error)"))
        }
        guard let combined = sealed.combined else {
            throw HVMError.encryption(.parseFailed(reason: "AES.GCM.SealedBox.combined nil"))
        }

        // 3. 拼装 header + ciphertext
        var out = Data()
        out.append(contentsOf: magic)
        out.append(formatVersion)
        out.append(contentsOf: [UInt8](repeating: 0, count: 3))
        out.append(combined)

        // 4. atomic write
        let target = configEncURL(bundleURL)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(configEncFileName).tmp")
        do {
            try out.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw HVMError.bundle(.writeFailed(reason: error.localizedDescription, path: target.path))
        }
    }

    // MARK: - load

    /// 读 <bundle>/config.yaml.enc + 解密 + YAML 解析 + validate. 密码错抛 .wrongPassword.
    public static func load(from bundleURL: URL,
                             key: SymmetricKey) throws -> VMConfig {
        let url = configEncURL(bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HVMError.bundle(.notFound(path: url.path))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: error.localizedDescription, path: url.path))
        }

        // 1. 头部校验
        guard data.count > headerLength else {
            throw HVMError.encryption(.parseFailed(reason: "encrypted config 文件过短 (\(data.count) bytes < header)"))
        }
        guard Array(data.prefix(4)) == magic else {
            throw HVMError.encryption(.parseFailed(reason: "encrypted config magic 不匹配"))
        }
        let ver = data[data.startIndex + 4]
        guard ver == formatVersion else {
            throw HVMError.encryption(.parseFailed(reason: "未知 format version: \(ver) (期望 \(formatVersion))"))
        }

        // 2. 提取 sealed box (跳过 8 字节 header)
        let combined = data.subdata(in: data.startIndex + headerLength ..< data.endIndex)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw HVMError.encryption(.parseFailed(reason: "SealedBox.combined 解析失败: \(error)"))
        }

        // 3. AES-GCM open. 失败原因可能是密码错 / 文件被改 — 都报 .wrongPassword (用户视角等价)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw HVMError.encryption(.wrongPassword)
        }

        // 4. YAML decode + validate
        let config: VMConfig
        do {
            config = try YAMLDecoder().decode(VMConfig.self, from: plaintext)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "解密后 YAML 解析失败: \(error)", path: url.path))
        }
        // 不在这里调 validate(): VMConfig.validate 校验 engine/guestOS 组合, 加密本身不影响.
        // 调用方 (BundleIO 路由层 / EncryptedBundleIO) 拿到后自行 validate.
        return config
    }
}
