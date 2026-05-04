// hvm-cli/Support/EncryptedConfigEditor.swift
// 加密-aware config 读写助手. 把 "明文 BundleIO" 与 "加密 EncryptedConfigIO" 路径
// 收敛成单一接口, 给 config/disk/iso/boot-from-disk 等子命令复用.
//
// 设计稿 docs/v3/TODO.md #1-#4 (CLI 适配缺失).
//
// 边界:
//   - VZ-sparsebundle: 暂未实现 (ENCRYPTION.md v2.4 QEMU 优先), 抛错
//   - QEMU-perfile: PasswordPrompt + EncryptedBundleIO.unlock + EncryptedConfigIO.save
//   - 明文 (无 routing JSON): BundleIO.load + BundleIO.save
//
// 临时解密的 config 只在内存里 mutate, 直接 EncryptedConfigIO.save 重写 .enc, 不落明文 yaml.

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

public enum EncryptedConfigEditor {

    /// 解锁会话. 持有加密 unlock handle (QEMU 路径); 明文场景为 nil.
    /// 调用方 `defer { try? session.close() }` 兜底清理 (QEMU 路径 close 是 no-op).
    public final class Session: @unchecked Sendable {
        public let bundleURL: URL
        public let scheme: EncryptionSpec.EncryptionScheme?  // nil = 明文
        let unlockHandle: EncryptedBundleIO.UnlockedHandle?

        init(bundleURL: URL,
             scheme: EncryptionSpec.EncryptionScheme?,
             unlockHandle: EncryptedBundleIO.UnlockedHandle?) {
            self.bundleURL = bundleURL
            self.scheme = scheme
            self.unlockHandle = unlockHandle
        }

        /// QEMU LUKS qcow2 / OVMF VARS / swtpm key / config.yaml.enc 4 把子 key.
        /// 明文 / VZ 场景 nil.
        public var qemuSubKeys: EncryptionKDF.SubKeySet? {
            unlockHandle?.qemuSubKeys
        }

        public var isEncrypted: Bool { scheme != nil }

        public func close() throws {
            try unlockHandle?.close()
        }
    }

    /// 加载 VM config. 加密 VM 走 PasswordPrompt + unlock; 明文走 BundleIO.load.
    /// - promptLabel: prompt 文案前缀 (典型 "VM 名"), 默认走 bundle name
    public static func load(bundleURL: URL,
                             promptLabel: String? = nil) throws -> (VMConfig, Session) {
        // 加密形态检测
        if let scheme = EncryptedBundleIO.detectScheme(at: bundleURL) {
            switch scheme {
            case .vzSparsebundle:
                throw HVMError.encryption(.parseFailed(
                    reason: "VZ 加密 VM 操作暂未实现 (ENCRYPTION.md v2.4 QEMU 优先); 等 VZ 接入 PR"
                ))
            case .qemuPerfile:
                let label = promptLabel ?? bundleURL.deletingPathExtension().lastPathComponent
                let password = try PasswordPrompt.read(prompt: "密码 (\(label)): ")
                let handle = try EncryptedBundleIO.unlock(bundlePath: bundleURL, password: password)
                let session = Session(bundleURL: bundleURL,
                                      scheme: .qemuPerfile,
                                      unlockHandle: handle)
                return (handle.config, session)
            }
        }

        // 明文
        let config = try BundleIO.load(from: bundleURL)
        let session = Session(bundleURL: bundleURL, scheme: nil, unlockHandle: nil)
        return (config, session)
    }

    /// 写回 VM config. 加密走 EncryptedConfigIO.save (用 session 持有的 sub key);
    /// 明文走 BundleIO.save. 中间不落明文 yaml.
    public static func save(_ config: VMConfig, session: Session) throws {
        guard let scheme = session.scheme else {
            try BundleIO.save(config: config, to: session.bundleURL)
            return
        }
        switch scheme {
        case .qemuPerfile:
            guard let subKeys = session.qemuSubKeys else {
                throw HVMError.encryption(.parseFailed(
                    reason: "EncryptedConfigEditor.save: session 无 qemuSubKeys (内部状态错)"
                ))
            }
            try EncryptedConfigIO.save(config: config,
                                        to: session.bundleURL,
                                        key: subKeys.config)
        case .vzSparsebundle:
            // load 阶段已挡, 兜底
            throw HVMError.encryption(.parseFailed(
                reason: "VZ 加密 VM save 暂未实现"
            ))
        }
    }
}
