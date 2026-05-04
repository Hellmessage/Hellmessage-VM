// HVMEncryption/DecryptVMOperation.swift
// 加密 QEMU VM → 明文 VM 冷迁移. 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b.
//
// 流程 (`hvm-cli decrypt <vm>`):
//   1. 校验 VM stopped + 加密形态
//   2. EncryptedBundleIO.unlock 拿 master + 4 子 keys
//   3. 临时目录 .decrypting-<8>/ 内:
//      - qemu-img convert LUKS qcow2 → qcow2 (主盘 / 数据盘 解密)
//      - qemu-img convert LUKS qcow2 → raw (OVMF VARS, Win VM)
//      - EncryptedConfigIO.load → BundleIO.save 写明文 config.yaml
//   4. 替换原文件: rm config.yaml.enc + meta/encryption.json + 加密 disks/nvram,
//      mv 临时明文进来
//   5. 完成后 rmdir 临时目录
//
// 失败回滚: 转换阶段失败 → 临时目录留, 主 bundle 不动. 替换阶段 mv 失败极少.
//
// 注:
// - decrypt 后 disks 仍是 qcow2 (不切回 raw / 不改 engine)
// - tpm/ 加密时已重置 (encrypt PR-10a 决策), decrypt 不动 — 仍是空, 启动时 swtpm 自建

import Foundation
import CryptoKit
import HVMBundle
import HVMCore

public enum DecryptVMOperation {
    private static let log = HVMLog.logger("encryption.decryptOp")

    public struct Result: Sendable {
        public let bundleURL: URL
    }

    public static func decrypt(bundleURL: URL,
                                password: String,
                                qemuImg: URL,
                                progressLog: ((String) -> Void)? = nil) throws -> Result {
        let log = progressLog ?? { _ in }

        // 1. 检测加密形态 + 解锁
        guard let scheme = EncryptedBundleIO.detectScheme(at: bundleURL),
              scheme == .qemuPerfile else {
            throw HVMError.encryption(.parseFailed(
                reason: "VM 不是加密形态 (or VZ-sparsebundle 不支持)"))
        }
        let handle = try EncryptedBundleIO.unlock(bundlePath: bundleURL, password: password)
        defer { try? handle.close() }
        guard let subKeys = handle.qemuSubKeys else {
            throw HVMError.encryption(.parseFailed(reason: "unlock 未返子 keys"))
        }
        var config = handle.config
        guard config.engine == .qemu else {
            throw HVMError.config(.invalidEnum(
                field: "engine", raw: config.engine.rawValue,
                allowed: ["qemu"]
            ))
        }

        // 2. 临时目录
        let tmpName = ".decrypting-\(UUID().uuidString.lowercased().prefix(8))"
        let tmpDir = bundleURL.appendingPathComponent(tmpName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("disks"),
                                                  withIntermediateDirectories: true)
        if config.guestOS == .windows {
            try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent("nvram"),
                                                      withIntermediateDirectories: true)
        }

        var rollbackTmpDir = true
        defer {
            if rollbackTmpDir {
                try? FileManager.default.removeItem(at: tmpDir)
            }
        }

        // 3. 解密每块 disk: LUKS qcow2 → qcow2
        for (i, disk) in config.disks.enumerated() {
            let srcURL = bundleURL.appendingPathComponent(disk.path)
            let baseName = (disk.path as NSString).lastPathComponent
            let dstTmp = tmpDir.appendingPathComponent("disks/\(baseName)")

            log("[\(i+1)/\(config.disks.count)] 解密磁盘 \(baseName) ...")
            try convertLuksToPlain(
                source: srcURL,
                destination: dstTmp,
                key: subKeys.qcow2Disk,
                outputFormat: "qcow2",
                qemuImg: qemuImg
            )
        }

        // 4. Win VM 解密 OVMF VARS: LUKS qcow2 → raw efi-vars.fd
        var nvramReplaced = false
        if config.guestOS == .windows {
            let srcVars = BundleLayout.nvramDir(bundleURL)
                .appendingPathComponent(BundleLayout.nvramLuksFileName)
            if FileManager.default.fileExists(atPath: srcVars.path) {
                let dstTmp = tmpDir.appendingPathComponent("nvram/\(BundleLayout.nvramFileName)")
                log("解密 OVMF VARS \(BundleLayout.nvramLuksFileName) → \(BundleLayout.nvramFileName) ...")
                try convertLuksToPlain(
                    source: srcVars,
                    destination: dstTmp,
                    key: subKeys.qcow2Nvram,
                    outputFormat: "raw",
                    qemuImg: qemuImg
                )
                nvramReplaced = true
            }
        }

        // 5. 解 config.yaml.enc → config.yaml (走 BundleIO.save 标准格式)
        config.encryption = nil   // 标记为明文
        let tmpConfigYaml = tmpDir.appendingPathComponent(BundleLayout.configFileName)
        // 用 BundleIO.save 写到一个临时 bundle dir 里, 再 mv 到 tmpConfigYaml
        let tmpCfgBundle = tmpDir.appendingPathComponent(".cfg-stage-\(UUID().uuidString.prefix(6))",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: tmpCfgBundle, withIntermediateDirectories: true)
        try BundleIO.save(config: config, to: tmpCfgBundle)
        try FileManager.default.moveItem(at: BundleLayout.configURL(tmpCfgBundle),
                                          to: tmpConfigYaml)
        try? FileManager.default.removeItem(at: tmpCfgBundle)

        // === 替换阶段 ===
        rollbackTmpDir = false
        log("✔ 转换完成, 替换原文件 ...")

        // 6. 删旧加密 disks
        let disksDir = BundleLayout.disksDir(bundleURL)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: disksDir.path) {
            for n in entries {
                try? FileManager.default.removeItem(atPath: "\(disksDir.path)/\(n)")
            }
        }
        // mv 临时 disks → 主 disks
        let tmpDisksDir = tmpDir.appendingPathComponent("disks")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDisksDir.path) {
            for n in names {
                try FileManager.default.moveItem(
                    at: tmpDisksDir.appendingPathComponent(n),
                    to: disksDir.appendingPathComponent(n)
                )
            }
        }

        // 7. NVRAM (Win)
        if nvramReplaced {
            let oldLuks = BundleLayout.nvramDir(bundleURL)
                .appendingPathComponent(BundleLayout.nvramLuksFileName)
            try? FileManager.default.removeItem(at: oldLuks)
            let from = tmpDir.appendingPathComponent("nvram/\(BundleLayout.nvramFileName)")
            let to = BundleLayout.nvramURL(bundleURL)
            try FileManager.default.moveItem(at: from, to: to)
        }

        // 8. config: 删 .enc + mv 明文
        let oldEnc = bundleURL.appendingPathComponent(EncryptedConfigIO.configEncFileName)
        try? FileManager.default.removeItem(at: oldEnc)
        let configFinal = BundleLayout.configURL(bundleURL)
        try? FileManager.default.removeItem(at: configFinal)
        try FileManager.default.moveItem(at: tmpConfigYaml, to: configFinal)

        // 9. 删 routing JSON
        try? FileManager.default.removeItem(at: RoutingJSON.locationForQemuBundle(bundleURL))

        // 10. tpm/ secure-erase (Win VM): swtpm state 是 swtpm-key 加密的,
        // decrypt 后没 swtpm-key 了, 必须清空 tpm/. 启动期 swtpm 在空目录初始化新明文 state.
        if config.guestOS == .windows {
            let tpmDir = BundleLayout.tpmStateDir(bundleURL)
            if FileManager.default.fileExists(atPath: tpmDir.path) {
                SecureErase.eraseDirectory(at: tpmDir)
                log("⚠ 已清 tpm/ (swtpm state 之前用 swtpm-key 加密, 解密后无 key); 启动后 swtpm 重新初始化空 state")
            }
        }

        try? FileManager.default.removeItem(at: tmpDir)
        Self.log.info("DecryptVMOperation 完成: \(bundleURL.lastPathComponent, privacy: .public)")
        return Result(bundleURL: bundleURL)
    }

    /// qemu-img convert LUKS qcow2 → 指定输出格式 (qcow2 / raw).
    private static func convertLuksToPlain(source: URL,
                                            destination: URL,
                                            key: SymmetricKey,
                                            outputFormat: String,
                                            qemuImg: URL) throws {
        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = [
            "convert",
            "--object", "secret,id=sec0,file=\(secret.path)",
            "--image-opts",
            "driver=qcow2,file.filename=\(source.path),encrypt.key-secret=sec0",
            "-O", outputFormat,
            destination.path,
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do { try proc.run() }
        catch {
            throw HVMError.encryption(.qemuImgFailed(verb: "convert", exitCode: -1,
                                                      stderr: "\(error)"))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw HVMError.encryption(.qemuImgFailed(
                verb: "convert (decrypt)",
                exitCode: proc.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }
}
