// HVMEncryption/RekeyVMOperation.swift
// 加密 QEMU VM 改密. 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b.
//
// 流程 (`hvm-cli rekey <vm>`):
//   1. 校验 VM stopped + 加密形态
//   2. EncryptedBundleIO.unlock(oldPassword) → oldSubKeys + config
//   3. 派生 newSalt + newMaster + newSubKeys
//   4. for each disk: QcowLuksFactory.rekey(oldKey: oldSubKeys.qcow2Disk, newKey: newSubKeys.qcow2Disk)
//      (走 amend 两步: add new keyslot → remove old keyslot)
//   5. nvram (Win): QcowLuksFactory.rekey
//   6. config.yaml.enc: 用 newSubKeys.config 重 seal (EncryptedConfigIO.save 覆写)
//   7. 写新 routing JSON (新 salt, 同 iter)
//   8. 重置 TPM (swtpm-key 也变, 现有 state 用 old swtpm-key 加密, 解不开)
//
// 中间失败处理: rekey 中途失败可能让 VM 半旧半新, 用户应记住老密码 + 重试 rekey.
// QcowLuksFactory.rekey 内部已有 .luksRekeyHalfDone 错误标记 step 2 失败的中间态.
//
// 不做:
// - swtpm rewrap (无工具; 当前重置 TPM)
// - 增量 / 部分 rekey (整 VM 一次性)

import Foundation
import CryptoKit
import HVMBundle
import HVMCore

public enum RekeyVMOperation {
    private static let log = HVMLog.logger("encryption.rekey")

    public struct Result: Sendable {
        public let bundleURL: URL
        public let tpmReset: Bool
    }

    public static func rekey(bundleURL: URL,
                              oldPassword: String,
                              newPassword: String,
                              qemuImg: URL,
                              progressLog: ((String) -> Void)? = nil) throws -> Result {
        let log = progressLog ?? { _ in }

        // 1. 解锁 (oldPassword)
        guard let scheme = EncryptedBundleIO.detectScheme(at: bundleURL),
              scheme == .qemuPerfile else {
            throw HVMError.encryption(.parseFailed(reason: "VM 不是加密形态"))
        }
        let handle = try EncryptedBundleIO.unlock(bundlePath: bundleURL, password: oldPassword)
        defer { try? handle.close() }
        guard let oldSubKeys = handle.qemuSubKeys else {
            throw HVMError.encryption(.parseFailed(reason: "unlock 未返子 keys"))
        }
        let config = handle.config

        // 2. 派生 new
        let newSalt = try PasswordKDF.generateSalt()
        let newMaster = try PasswordKDF.deriveMasterKey(password: newPassword, salt: newSalt)
        let newSubKeys = EncryptionKDF.deriveAll(masterKey: newMaster)

        // 3. 改 disks 密
        for (i, disk) in config.disks.enumerated() {
            let diskURL = bundleURL.appendingPathComponent(disk.path)
            let baseName = (disk.path as NSString).lastPathComponent
            log("[\(i+1)/\(config.disks.count)] rekey 磁盘 \(baseName) ...")
            try QcowLuksFactory.rekey(
                at: diskURL,
                oldKey: oldSubKeys.qcow2Disk,
                newKey: newSubKeys.qcow2Disk,
                qemuImg: qemuImg
            )
        }

        // 4. 改 nvram 密 (Win)
        if config.guestOS == .windows {
            let nvramURL = BundleLayout.nvramDir(bundleURL)
                .appendingPathComponent(BundleLayout.nvramLuksFileName)
            if FileManager.default.fileExists(atPath: nvramURL.path) {
                log("rekey OVMF VARS \(BundleLayout.nvramLuksFileName) ...")
                try QcowLuksFactory.rekey(
                    at: nvramURL,
                    oldKey: oldSubKeys.qcow2Nvram,
                    newKey: newSubKeys.qcow2Nvram,
                    qemuImg: qemuImg
                )
            }
        }

        // 5. config.yaml.enc 用新 config-key 重 seal
        // 注: encryption.createdAt 不变 (代表 VM 加密的初始时间, 不是密码 rotation 时间)
        log("重新加密 config.yaml.enc ...")
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: newSubKeys.config)

        // 6. 写新 routing JSON (覆写老的)
        let routing = RoutingMetadata(
            vmId: config.id,
            scheme: .qemuPerfile,
            displayName: config.displayName,
            kdfSalt: newSalt
        )
        try RoutingJSON.write(routing, to: RoutingJSON.locationForQemuBundle(bundleURL))

        // 7. 重置 TPM (Win): 现有 state 用 old swtpm-key 加密, 用 new swtpm-key 解不开.
        // 直接 secure-erase 整 tpm/, 启动期 swtpm 用 new swtpm-key 重新初始化.
        var tpmReset = false
        if config.guestOS == .windows {
            let tpmDir = BundleLayout.tpmStateDir(bundleURL)
            if FileManager.default.fileExists(atPath: tpmDir.path) {
                SecureErase.eraseDirectory(at: tpmDir)
                tpmReset = true
                log("⚠ 已重置 TPM 状态 (改密会让 swtpm-key 变, 现有 state 解不开; BitLocker 状态丢)")
            }
        }

        Self.log.info("RekeyVMOperation 完成: \(bundleURL.lastPathComponent, privacy: .public)")
        return Result(bundleURL: bundleURL, tpmReset: tpmReset)
    }
}
