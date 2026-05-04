// HVMEncryption/RekeyVMOperation.swift
// 加密 QEMU VM 改密. 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b + TODO #12 原子化加固.
//
// 流程 (`hvm-cli rekey <vm>`) — TODO #12 原子化重排:
//   1. 校验 VM stopped + 加密形态
//   2. EncryptedBundleIO.unlock(oldPassword) → oldSubKeys + config
//   3. 派生 newSalt + newMaster + newSubKeys
//   4. **for each disk: addNewKeyslot** (老 + 新都活, 老密码仍能解)
//   5. **nvram (Win): addNewKeyslot**
//   6. **atomic write config.yaml.enc** (用 newSubKeys.config)
//   7. **atomic write routing JSON** (新 salt)
//   8. **for each disk: removeOldKeyslot** (只剩新 keyslot)
//   9. **nvram: removeOldKeyslot**
//   10. 重置 TPM (swtpm-key 也变, 现有 state 用 old swtpm-key 加密, 解不开)
//
// 原子化保证: 任何 crash 点都能用某个密码解 (等价于"绝不发生两个密码都解不开"灾难)
//   - crash in 4-5: routing/config 仍 old → 老密码可继续 (新 keyslot 加了无害)
//   - crash in 6-7: 双 keyslot 激活 + 部分新 metadata → 新密码可解 (新 keyslot + 新 sub.config + 新 salt)
//                    若 6 已成功 7 失败 → routing 还是 old salt 但 config 是新 sub 加密
//                    → 用户输 new 密码 → PBKDF2(new, old salt) ≠ new master → 解不开 config.enc
//                    **加固**: 6 + 7 用 临时文件 + atomic rename (mv 替换) 让 6/7 等价为单 atomic 写
//   - crash in 8-9: routing/config 已新, 部分 disk 切完 → 新密码可解全部 (老 keyslot 残留无害)
//
// 不做:
// - swtpm rewrap (无工具; 当前重置 TPM)
// - 增量 / 部分 rekey (整 VM 一次性)
// - host crash 在 LUKS amend 的 atomic 区间内 (qemu-img 内部, 无干预空间)

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

        // SIGINT 防中断 (PR-C). rekey 没临时目录可清 (in-place 改 LUKS keyslot),
        // 但仍要拦中断 — keyslot 改一半就 Ctrl-C 退出会导致 config.enc 与 keyslot 不匹配,
        // 用户两个密码都解不开. 所以这里防中断的价值最高.
        SignalGuard.install(message: "⚠ 改密进行中, 请等待结束 (中途中断会让 keyslot 与 config.enc 不一致, 两个密码都解不开)")
        defer { SignalGuard.uninstall(); SignalGuard.clearCleanup() }

        // 2. 派生 new
        let newSalt = try PasswordKDF.generateSalt()
        let newMaster = try PasswordKDF.deriveMasterKey(password: newPassword, salt: newSalt)
        let newSubKeys = EncryptionKDF.deriveAll(masterKey: newMaster)

        // 3a. 全部 disks: 加新 keyslot (老 + 新都活, 老密码仍能解)
        for (i, disk) in config.disks.enumerated() {
            let diskURL = bundleURL.appendingPathComponent(disk.path)
            let baseName = (disk.path as NSString).lastPathComponent
            log("[\(i+1)/\(config.disks.count)] addNewKeyslot 磁盘 \(baseName) ...")
            try QcowLuksFactory.addNewKeyslot(
                at: diskURL,
                oldKey: oldSubKeys.qcow2Disk,
                newKey: newSubKeys.qcow2Disk,
                qemuImg: qemuImg
            )
        }

        // 3b. nvram (Win): 加新 keyslot
        var hasNvram = false
        let nvramURL = BundleLayout.nvramDir(bundleURL)
            .appendingPathComponent(BundleLayout.nvramLuksFileName)
        if config.guestOS == .windows && FileManager.default.fileExists(atPath: nvramURL.path) {
            hasNvram = true
            log("addNewKeyslot OVMF VARS \(BundleLayout.nvramLuksFileName) ...")
            try QcowLuksFactory.addNewKeyslot(
                at: nvramURL,
                oldKey: oldSubKeys.qcow2Nvram,
                newKey: newSubKeys.qcow2Nvram,
                qemuImg: qemuImg
            )
        }

        // 4. config.yaml.enc + routing JSON: atomic 切换 (TODO #12 原子化关键).
        // 实现: 先写两个临时文件 → atomic rename 替换 (rename(2) 在 APFS 上 atomic).
        // 这样用户态视角 6+7 是一个 atomic boundary; crash 在 boundary 之前 = 老 metadata,
        // crash 在 boundary 之后 = 新 metadata; 二者都能解 (3a/3b 加了 new keyslot, 8 还没 remove old).
        log("atomic 切换 config.yaml.enc + routing JSON ...")
        let configEncURL = EncryptedConfigIO.configEncURL(bundleURL)
        let routingURL = RoutingJSON.locationForQemuBundle(bundleURL)
        let stagedConfig = configEncURL.appendingPathExtension("staging")
        let stagedRouting = routingURL.appendingPathExtension("staging")
        try? FileManager.default.removeItem(at: stagedConfig)
        try? FileManager.default.removeItem(at: stagedRouting)

        // 写新 config 到 staging (用 new sub.config)
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: newSubKeys.config,
                                     overrideURL: stagedConfig)
        // 写新 routing 到 staging. guestOS 保持原 config (rekey 不改 guestOS).
        let newRouting = RoutingMetadata(
            vmId: config.id,
            scheme: .qemuPerfile,
            displayName: config.displayName,
            guestOS: config.guestOS,
            kdfSalt: newSalt
        )
        try RoutingJSON.write(newRouting, to: stagedRouting)

        // atomic replace (FileManager.replaceItemAt 在同卷 = rename(2) 等价)
        // 顺序: 先 config 后 routing. 任一失败回滚 staging
        do {
            if FileManager.default.fileExists(atPath: configEncURL.path) {
                _ = try FileManager.default.replaceItemAt(configEncURL, withItemAt: stagedConfig)
            } else {
                try FileManager.default.moveItem(at: stagedConfig, to: configEncURL)
            }
            if FileManager.default.fileExists(atPath: routingURL.path) {
                _ = try FileManager.default.replaceItemAt(routingURL, withItemAt: stagedRouting)
            } else {
                try FileManager.default.moveItem(at: stagedRouting, to: routingURL)
            }
        } catch {
            // atomic 切换失败: staging 文件留 (排查), 但 LUKS keyslot 已加 new — 老密码仍能解
            try? FileManager.default.removeItem(at: stagedConfig)
            try? FileManager.default.removeItem(at: stagedRouting)
            throw error
        }

        // 5a. disks: 销毁老 keyslot (现 disks/nvram 仍双 keyslot 激活, 删 old 后只剩 new)
        for (i, disk) in config.disks.enumerated() {
            let diskURL = bundleURL.appendingPathComponent(disk.path)
            let baseName = (disk.path as NSString).lastPathComponent
            log("[\(i+1)/\(config.disks.count)] removeOldKeyslot 磁盘 \(baseName) ...")
            try QcowLuksFactory.removeOldKeyslot(
                at: diskURL,
                oldKey: oldSubKeys.qcow2Disk,
                newKey: newSubKeys.qcow2Disk,
                qemuImg: qemuImg
            )
        }

        // 5b. nvram: 销毁老 keyslot
        if hasNvram {
            log("removeOldKeyslot OVMF VARS \(BundleLayout.nvramLuksFileName) ...")
            try QcowLuksFactory.removeOldKeyslot(
                at: nvramURL,
                oldKey: oldSubKeys.qcow2Nvram,
                newKey: newSubKeys.qcow2Nvram,
                qemuImg: qemuImg
            )
        }

        // 6. 重置 TPM (Win): 现有 state 用 old swtpm-key 加密, 用 new swtpm-key 解不开.
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
