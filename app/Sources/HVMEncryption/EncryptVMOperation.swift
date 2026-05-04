// HVMEncryption/EncryptVMOperation.swift
// 老明文 QEMU VM → 加密 VM 冷迁移. 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10a.
//
// 流程 (`hvm-cli encrypt <vm>`):
//   1. 校验 VM stopped (调用方抢 .edit lock)
//   2. 校验 engine == .qemu (VZ engine 暂不支持: raw → LUKS qcow2 切引擎需独立 PR)
//   3. 用户输 password (调用方 prompt)
//   4. 派生 master KEK (PBKDF2) + 4 子 keys (HKDF)
//   5. 临时目录 .encrypting-<random>/ 旁建临时加密文件 (失败可清, 不破原数据)
//   6. disks/*.qcow2 / *.img → 临时目录/<name>.qcow2 (LUKS) via qemu-img convert
//   7. nvram/efi-vars.fd → 临时目录/efi-vars.qcow2 via OVMFVarsLuksFactory.create
//   8. config + routing JSON 写完 → 全部 OK
//   9. 替换原文件: rm 老明文, mv 新加密, rmdir 临时目录
//
// 失败回滚: 任意步骤抛错 → 临时目录留着, 主 bundle 未动. 用户可手动清 .encrypting-*.
// 失败也不写 routing JSON / config.yaml.enc, 主 bundle 保持明文状态.
//
// TPM 重置 (Win VM): 现有 swtpm state 是明文 binary, 用新 swtpm-key 启动时 swtpm 解不开
// (它会用 key 试解密, fail). 简化决策: 加密后**重置 TPM** (rm tpm/), 用户警告
// "BitLocker / SecureBoot 信任根重置, 系统首次启动会重新 attest". 用户自觉重新装 BitLocker.
// 真正 swtpm rewrap 留 PR-后续.
//
// 不做:
// - VZ engine VM (raw .img 切 LUKS qcow2 改 engine, 涉及 boot loader 等, 单独 PR)
// - 增量加密 (一次必须把整 VM disks 全转, 不支持只加密部分)
// - 在线加密 (VM 必须 stopped)

import Foundation
import CryptoKit
import HVMBundle
import HVMCore

public enum EncryptVMOperation {
    private static let log = HVMLog.logger("encryption.encryptOp")

    public struct Result: Sendable {
        public let bundleURL: URL
        public let originalSchemeWasEncrypted: Bool
        /// Win VM 时 true (TPM state 已重置)
        public let tpmReset: Bool
    }

    /// 把现有明文 QEMU VM 转加密. password 由调用方 prompt + 双重确认.
    /// - Parameter bundleURL: 现有 .hvmz 路径
    /// - Parameter password: 用户密码 (跨机器 portable 唯一来源)
    /// - Parameter qemuImg: HVM 包内 qemu-img
    /// - Parameter ovmfVarsTemplate: stock OVMF VARS 模板 (Win VM 时需要; nil 则非 Win 不需要)
    /// - Parameter progressLog: 进度日志 (磁盘转换可能分钟级, 调用方接 log 给 user)
    public static func encrypt(bundleURL: URL,
                                password: String,
                                qemuImg: URL,
                                ovmfVarsTemplate: URL?,
                                progressLog: ((String) -> Void)? = nil) throws -> Result {
        let log = progressLog ?? { _ in }

        // 0. 检测当前形态 — 已加密的拒绝
        if EncryptedBundleIO.detectScheme(at: bundleURL) != nil {
            throw HVMError.encryption(.parseFailed(
                reason: "VM 已经是加密形态, 不能再次 encrypt"
            ))
        }

        // 1. 加载 config 校验 engine + guestOS
        var config: VMConfig
        do {
            config = try BundleIO.load(from: bundleURL)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "加载 config 失败: \(error)",
                                                path: bundleURL.path))
        }
        guard config.engine == .qemu else {
            throw HVMError.config(.invalidEnum(
                field: "engine", raw: config.engine.rawValue,
                allowed: ["qemu (VZ engine VM 加密暂不支持; v2.4 决策)"]
            ))
        }
        guard config.guestOS != .macOS else {
            throw HVMError.config(.invalidEnum(
                field: "guestOS", raw: "macOS",
                allowed: ["linux / windows (macOS 走 VZ, 加密推后)"]
            ))
        }

        // 2. KDF: 生成 salt + master + 4 子 keys
        let salt = try PasswordKDF.generateSalt()
        let master = try PasswordKDF.deriveMasterKey(password: password, salt: salt)
        let subKeys = EncryptionKDF.deriveAll(masterKey: master)

        // 3. 临时目录 .encrypting-<8 char>/
        let tmpName = ".encrypting-\(UUID().uuidString.lowercased().prefix(8))"
        let tmpDir = bundleURL.appendingPathComponent(tmpName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("disks"),
                                                  withIntermediateDirectories: true)
        if config.guestOS == .windows {
            try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("nvram"),
                                                      withIntermediateDirectories: true)
        }

        // SIGINT 防中断 + 兜底清理 (PR-C). atexit / 二次 Ctrl-C 硬退时跑.
        SignalGuard.install(message: "⚠ 加密操作进行中, 请等待结束 (再次 Ctrl-C 强制退出, 临时目录可能残留)")
        SignalGuard.registerCleanup {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        defer { SignalGuard.uninstall(); SignalGuard.clearCleanup() }

        // 失败时清临时目录 (保护 main bundle 不动)
        var rollbackTmpDir = true
        defer {
            if rollbackTmpDir {
                try? FileManager.default.removeItem(at: tmpDir)
            }
        }

        // 4. 转换每块 disk: raw / qcow2 → LUKS qcow2 (在临时目录里)
        var newDisks = config.disks
        for (i, disk) in config.disks.enumerated() {
            let srcURL = bundleURL.appendingPathComponent(disk.path)
            // 加密版主盘 / 数据盘统一改成 .qcow2 后缀 (DiskFormat.qcow2)
            let baseName = (disk.path as NSString).lastPathComponent
            let nameWithoutExt = (baseName as NSString).deletingPathExtension
            let newName = "\(nameWithoutExt).qcow2"
            let newRel = "\(BundleLayout.disksDirName)/\(newName)"
            let dstTmp = tmpDir.appendingPathComponent("disks/\(newName)")

            log("[\(i+1)/\(config.disks.count)] 加密磁盘 \(baseName) → \(newName) ...")
            try convertDiskToLuks(
                source: srcURL,
                sourceFormat: disk.format,
                destination: dstTmp,
                key: subKeys.qcow2Disk,
                qemuImg: qemuImg
            )

            newDisks[i].path = newRel
            newDisks[i].format = .qcow2
        }

        // 5. Windows VM: 转 OVMF VARS
        var nvramReplaced = false
        if config.guestOS == .windows {
            guard let template = ovmfVarsTemplate else {
                throw HVMError.config(.missingField(
                    name: "ovmfVarsTemplate (Win VM 加密需要 OVMF VARS 模板)"))
            }
            // 现有 nvram/efi-vars.fd 可能没装机过 (template 直接用); 装过的也直接用 stock template,
            // 因为 OVMF 加密 VARS 启动后会自己写入 (BootOrder 等会丢, 但这是 user warning).
            // 实际我们应保留现有 vars 内容: 用 qemu-img convert -f raw -O qcow2 -o encrypt 转换.
            let srcVars = BundleLayout.nvramURL(bundleURL)
            let dstTmp = tmpDir.appendingPathComponent("nvram/\(BundleLayout.nvramLuksFileName)")

            log("加密 OVMF VARS \(BundleLayout.nvramFileName) → \(BundleLayout.nvramLuksFileName) ...")
            if FileManager.default.fileExists(atPath: srcVars.path) {
                // 现有 vars: convert raw → LUKS qcow2 (保留 BootOrder)
                try convertDiskToLuks(
                    source: srcVars,
                    sourceFormat: .raw,
                    destination: dstTmp,
                    key: subKeys.qcow2Nvram,
                    qemuImg: qemuImg
                )
            } else {
                // 没现有 vars (新 VM 还没 boot 过): 用 stock template
                try OVMFVarsLuksFactory.create(
                    at: dstTmp,
                    fromTemplate: template,
                    key: subKeys.qcow2Nvram,
                    qemuImg: qemuImg
                )
                _ = template  // suppress
            }
            nvramReplaced = true
        }

        // 6. 加密 config.yaml: 在临时目录写 config.yaml.enc
        config.encryption = EncryptionSpec(
            enabled: true,
            scheme: .qemuPerfile,
            createdAt: Date()
        )
        config.disks = newDisks   // 更新 disk paths
        let tmpConfigEnc = tmpDir.appendingPathComponent(EncryptedConfigIO.configEncFileName)
        // EncryptedConfigIO.save 写到 <bundle>/config.yaml.enc; 这里走临时目录, 自己 in-line.
        try saveEncryptedConfig(config: config, key: subKeys.config, to: tmpConfigEnc)

        // 7. 写临时 routing JSON
        let routing = RoutingMetadata(
            vmId: config.id,
            scheme: .qemuPerfile,
            displayName: config.displayName,
            kdfSalt: salt
        )
        let tmpRoutingURL = tmpDir.appendingPathComponent("encryption.json")
        try RoutingJSON.write(routing, to: tmpRoutingURL)

        // === 全部转换 OK, 进入"替换原文件"阶段, rollback 不再可行 ===
        rollbackTmpDir = false
        log("✔ 转换完成, 替换原文件 ...")

        // 8. 删旧明文 disks (best-effort secure-erase 单 pass random + unlink)
        let disksDir = BundleLayout.disksDir(bundleURL)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: disksDir.path) {
            for n in entries {
                SecureErase.eraseFile(at: disksDir.appendingPathComponent(n))
            }
        }
        // mv 临时 disks → 主 disks
        let tmpDisksDir = tmpDir.appendingPathComponent("disks")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDisksDir.path) {
            for n in names {
                let from = tmpDisksDir.appendingPathComponent(n)
                let to = disksDir.appendingPathComponent(n)
                try FileManager.default.moveItem(at: from, to: to)
            }
        }

        // 9. NVRAM (Win) — secure-erase 旧明文 efi-vars.fd
        if nvramReplaced {
            let oldVars = BundleLayout.nvramURL(bundleURL)
            SecureErase.eraseFile(at: oldVars)
            let from = tmpDir.appendingPathComponent("nvram/\(BundleLayout.nvramLuksFileName)")
            let to = BundleLayout.nvramDir(bundleURL).appendingPathComponent(BundleLayout.nvramLuksFileName)
            try FileManager.default.moveItem(at: from, to: to)
        }

        // 10. config.yaml.enc + secure-erase 旧 config.yaml (含 MAC / 设备信息等)
        let oldConfigYaml = BundleLayout.configURL(bundleURL)
        let newConfigEnc = bundleURL.appendingPathComponent(EncryptedConfigIO.configEncFileName)
        try? FileManager.default.removeItem(at: newConfigEnc)
        try FileManager.default.moveItem(at: tmpConfigEnc, to: newConfigEnc)
        SecureErase.eraseFile(at: oldConfigYaml)

        // 11. routing JSON 写到 meta/encryption.json
        let metaDir = BundleLayout.metaDir(bundleURL)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let routingFinal = RoutingJSON.locationForQemuBundle(bundleURL)
        try? FileManager.default.removeItem(at: routingFinal)
        try FileManager.default.moveItem(at: tmpRoutingURL, to: routingFinal)

        // 12. Windows: 重置 TPM. 走 SecureErase 而非裸 rm — tpm/permall 含 BitLocker
        // recovery key / TPM-sealed secrets, 这些是高敏感.
        var tpmReset = false
        if config.guestOS == .windows {
            let tpmDir = BundleLayout.tpmStateDir(bundleURL)
            if FileManager.default.fileExists(atPath: tpmDir.path) {
                SecureErase.eraseDirectory(at: tpmDir)
                tpmReset = true
                log("⚠ 已 secure-erase 旧 TPM 状态 (BitLocker recovery key 等已覆写); 新 swtpm-key 加密 state 首启自建")
            }
        }

        // 13. 清临时目录
        try? FileManager.default.removeItem(at: tmpDir)

        Self.log.info("EncryptVMOperation 完成: \(bundleURL.lastPathComponent, privacy: .public) (tpmReset=\(tpmReset))")

        return Result(
            bundleURL: bundleURL,
            originalSchemeWasEncrypted: false,
            tpmReset: tpmReset
        )
    }

    // MARK: - 内部 helper

    /// qemu-img convert raw / qcow2 → LUKS qcow2.
    /// 走 LuksSecretFile (base64 ASCII passphrase).
    private static func convertDiskToLuks(source: URL,
                                            sourceFormat: DiskFormat,
                                            destination: URL,
                                            key: SymmetricKey,
                                            qemuImg: URL) throws {
        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = [
            "convert",
            "--object", "secret,id=sec0,file=\(secret.path)",
            "-f", sourceFormat.rawValue,
            "-O", "qcow2",
            "-o", "encrypt.format=luks,encrypt.key-secret=sec0,encrypt.cipher-alg=aes-256,encrypt.cipher-mode=xts",
            source.path,
            destination.path,
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do { try proc.run() }
        catch {
            throw HVMError.encryption(.qemuImgFailed(verb: "convert", exitCode: -1,
                                                      stderr: "无法启动: \(error)"))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw HVMError.encryption(.qemuImgFailed(
                verb: "convert (encrypt)",
                exitCode: proc.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }

    /// 写 EncryptedConfigIO 格式 (HENC + AES-GCM SealedBox.combined) 到指定路径.
    /// EncryptedConfigIO.save 写到 <bundle>/config.yaml.enc 固定位置, 这里允许任意 url.
    private static func saveEncryptedConfig(config: VMConfig, key: SymmetricKey, to url: URL) throws {
        // 复用 EncryptedConfigIO 主体逻辑. 简便: copy 文件实现 inline 等价代码.
        // 走 EncryptedConfigIO.save 到一个临时 bundle URL 然后 mv?
        // 简化: 直接调 EncryptedConfigIO.save 到一个临时 bundle dir, 再 mv config.yaml.enc 到 url.
        let tmpBundle = url.deletingLastPathComponent().appendingPathComponent(".cfg-tmp-\(UUID().uuidString.prefix(6))",
                                                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBundle) }

        try EncryptedConfigIO.save(config: config, to: tmpBundle, key: key)
        let src = EncryptedConfigIO.configEncURL(tmpBundle)
        try FileManager.default.moveItem(at: src, to: url)
    }
}
