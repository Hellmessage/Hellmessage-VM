// HVMStorage/CloneManager.swift
// 整 VM 克隆: APFS clonefile(2) 复制磁盘 + nvram/tpm/auxiliary/meta + 重生身份字段.
//
// 重生: config.id / displayName / createdAt / 数据盘 uuid8(+DiskSpec.path) / networks[].mac
//       (keepMACAddresses=true 时保留 mac).
// 保留: 主盘文件名 (按 engine 固定) / nvram efi-vars (重置 = guest 进 EFI Shell) /
//       tpm (重置 = BitLocker 永久失效).
// 不带: .lock / logs/ 内容 / Windows 装机产物 (unattend.iso 等) / snapshots/.
//
// 加密 VM (D9 = 等价复制 + 同密码): clonefile 字节级 COW 复制 LUKS qcow2 / swtpm state 不解密;
//   salt + 密码不变 → 同 master KEK → 同 keyslot 可解; config.yaml.enc 解密改字段后用源 sub.config
//   重新加密; routing JSON 仅改 vmId/displayName. 想换密码用户自跑 hvm-cli rekey.
//
// 前置约束: 源必须 stopped (内部抢 .edit lock, 被 .runtime 占抛 .busy); 源 + 目标父目录必须同
//   APFS 卷 (clonefile 跨卷 EXDEV, 提前 stat st_dev 探测); 目标不能预存在; 加密源必须传 password;
//   失败时清理目标残留 (不留 partial bundle).

import Foundation
import Darwin
import HVMCore
import HVMBundle
import HVMEncryption
import HVMNet

public enum CloneManager {
    private static let log = HVMLog.logger("storage.clone")

    public struct Options: Sendable {
        /// 新 VM 显示名 (1-64 字符, 不允许 / NUL)
        public var newDisplayName: String
        /// 目标父目录, nil = 源父目录
        public var targetParentDir: URL?
        /// true = 保留所有 NIC MAC (用户自负: 同 LAN 双开会冲突)
        public var keepMACAddresses: Bool
        /// 加密源 VM 时调用方 prompt 后传入 (跨机器 portable 唯一来源).
        /// 明文源 VM 必须 nil (传了也 ignore).
        public var password: String?

        public init(newDisplayName: String,
                    targetParentDir: URL? = nil,
                    keepMACAddresses: Bool = false,
                    password: String? = nil) {
            self.newDisplayName = newDisplayName
            self.targetParentDir = targetParentDir
            self.keepMACAddresses = keepMACAddresses
            self.password = password
        }
    }

    public struct Result: Sendable {
        public let sourceBundle: URL
        public let targetBundle: URL
        public let newID: UUID
        /// 数据盘 uuid8 老→新映射 (诊断用; 仅成功 clone 的盘记录)
        public let renamedDataDiskUUID8s: [String: String]
    }

    /// 执行整 VM 克隆. 成功 = 完整可用的新 bundle; 失败 = 没有 partial 残留.
    /// 加密源 VM 必须传 options.password (CLI 层 prompt). 明文源 VM password 应为 nil.
    public static func clone(sourceBundle: URL, options: Options) throws -> Result {
        try validateName(options.newDisplayName)

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceBundle.path) else {
            throw HVMError.bundle(.notFound(path: sourceBundle.path))
        }

        // 目标路径: <targetParentDir or 源父>/<newDisplayName>.hvmz
        let parent = options.targetParentDir ?? sourceBundle.deletingLastPathComponent()
        let targetBundle = parent.appendingPathComponent("\(options.newDisplayName).hvmz",
                                                          isDirectory: true)
        if fm.fileExists(atPath: targetBundle.path) {
            throw HVMError.bundle(.alreadyExists(path: targetBundle.path))
        }
        // parent 必须存在, 否则下面创建子目录会失败
        if !fm.fileExists(atPath: parent.path) {
            throw HVMError.bundle(.notFound(path: parent.path))
        }

        // 同卷校验: clonefile 跨卷 EXDEV. 比 st_dev 即可.
        try ensureSameVolume(sourceBundle, parent)

        // 抢源 .edit lock 防止运行中克隆 (非阻塞, 已被 .runtime 占就抛 .busy)
        let srcLock = try BundleLock(bundleURL: sourceBundle, mode: .edit)
        defer { srcLock.release() }

        // 加密形态分流 (D9 = 等价复制 + 同密码)
        if EncryptedBundleIO.detectScheme(at: sourceBundle) != nil {
            // QEMU-only: 加密 VM 恒 qemu-perfile (vz-sparsebundle 已随 VZ 移除)
            guard let password = options.password else {
                throw HVMError.config(.missingField(name: "password (加密 VM clone 必须传 password)"))
            }
            return try cloneEncryptedQEMU(sourceBundle: sourceBundle,
                                          targetBundle: targetBundle,
                                          options: options,
                                          password: password)
        }

        // 加载源 config (走 schema 升级链 + 校验)
        var config = try BundleIO.load(from: sourceBundle)

        Self.log.info("clone start (plaintext): \(sourceBundle.lastPathComponent, privacy: .public) → \(targetBundle.lastPathComponent, privacy: .public)")

        var renamed: [String: String] = [:]
        let newID = UUID()
        do {
            // 目标骨架
            try fm.createDirectory(at: targetBundle, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: BundleLayout.disksDir(targetBundle),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])

            // 主盘: 文件名不变, cloneFile
            guard let mainDisk = config.disks.first(where: { $0.role == .main }) else {
                throw HVMError.config(.missingField(name: "disks 中无 role=main 的盘"))
            }
            try cloneFile(from: sourceBundle.appendingPathComponent(mainDisk.path),
                          to: targetBundle.appendingPathComponent(mainDisk.path))

            // 数据盘: uuid8 重生 → 改文件名 + DiskSpec.path
            for i in config.disks.indices where config.disks[i].role == .data {
                let oldDisk = config.disks[i]
                let oldName = (oldDisk.path as NSString).lastPathComponent
                let oldUUID8 = extractDataDiskUUID8(oldName)
                let newUUID8 = DiskFactory.newDataDiskUUID8()
                let newName = BundleLayout.dataDiskFileName(uuid8: newUUID8, engine: config.engine)
                let newRel = "\(BundleLayout.disksDirName)/\(newName)"
                try cloneFile(from: sourceBundle.appendingPathComponent(oldDisk.path),
                              to: targetBundle.appendingPathComponent(newRel))
                config.disks[i].path = newRel
                if let old = oldUUID8 {
                    renamed[old] = newUUID8
                }
            }

            // 装机产物子目录: 整目录 cloneFile (clonefile 支持 dir; dst 不存在为前提)
            try cloneIfExists(name: BundleLayout.nvramDirName, from: sourceBundle, to: targetBundle)
            try cloneIfExists(name: "tpm", from: sourceBundle, to: targetBundle)
            try cloneIfExists(name: BundleLayout.auxiliaryDirName, from: sourceBundle, to: targetBundle)
            try cloneIfExists(name: BundleLayout.metaDirName, from: sourceBundle, to: targetBundle)

            // logs/ 空目录: QemuConsoleBridge 启动时写
            try fm.createDirectory(at: BundleLayout.logsDir(targetBundle),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])

            // 重生身份字段
            config.id = newID
            config.displayName = options.newDisplayName
            config.createdAt = Date()
            if !options.keepMACAddresses {
                for i in config.networks.indices {
                    config.networks[i].macAddress = MACAddressGenerator.random()
                }
            }

            // 写目标 config.yaml (validate 在 save 内调)
            try BundleIO.save(config: config, to: targetBundle)
        } catch {
            // 任意一步失败 → 清掉目标残留. 已分配的 clonefile inode 随 unlink 释放.
            try? fm.removeItem(at: targetBundle)
            throw error
        }

        Self.log.info("clone done: \(sourceBundle.lastPathComponent, privacy: .public) → \(targetBundle.lastPathComponent, privacy: .public) newID=\(newID.uuidString, privacy: .public) renamedDataDisks=\(renamed.count)")

        return Result(sourceBundle: sourceBundle,
                      targetBundle: targetBundle,
                      newID: newID,
                      renamedDataDiskUUID8s: renamed)
    }

    // MARK: - 内部 helper

    /// 显示名校验: 1-64 字符, 不允许 / NUL / "." / "..".
    /// 比 SnapshotManager 略宽, 允许中文 / 空格 (与 BundleIO 行为一致).
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64 else {
            throw HVMError.config(.invalidEnum(field: "displayName",
                                                raw: name,
                                                allowed: ["1-64 字符"]))
        }
        guard name != "." && name != ".." else {
            throw HVMError.config(.invalidEnum(field: "displayName",
                                                raw: name,
                                                allowed: ["不能是 . 或 .."]))
        }
        if name.contains("/") || name.contains("\0") {
            throw HVMError.config(.invalidEnum(field: "displayName",
                                                raw: name,
                                                allowed: ["不允许 / 或 NUL"]))
        }
    }

    /// 同卷判定: 比 stat.st_dev. 跨卷 clonefile 会 EXDEV, 提前抛更友好.
    private static func ensureSameVolume(_ a: URL, _ b: URL) throws {
        var sa = stat()
        var sb = stat()
        if stat(a.path, &sa) != 0 {
            throw HVMError.storage(.ioError(errno: errno, path: a.path))
        }
        if stat(b.path, &sb) != 0 {
            throw HVMError.storage(.ioError(errno: errno, path: b.path))
        }
        if sa.st_dev != sb.st_dev {
            throw HVMError.storage(.crossVolumeNotAllowed(source: a.path, target: b.path))
        }
    }

    /// 子目录存在则 clonefile 整体过去 (递归 COW); 不存在则 noop.
    /// 注: clonefile(2) 要求 dst 不存在.
    private static func cloneIfExists(name: String, from src: URL, to dst: URL) throws {
        let s = src.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: s.path) else { return }
        let d = dst.appendingPathComponent(name, isDirectory: true)
        try cloneFile(from: s, to: d)
    }

    /// SnapshotManager.cloneFile 的本模块别名 (复用同一份 clonefile(2) 包装). flags=0 = 等价 cp -c.
    private static func cloneFile(from src: URL, to dst: URL) throws {
        try SnapshotManager.cloneFile(from: src, to: dst)
    }

    /// 从 "data-<uuid8>.<ext>" 抽 uuid8 (8 位小写 hex). 不符规范的老文件名返 nil.
    private static func extractDataDiskUUID8(_ filename: String) -> String? {
        guard filename.hasPrefix("data-") else { return nil }
        let afterPrefix = filename.dropFirst("data-".count)
        guard let dotIdx = afterPrefix.firstIndex(of: ".") else { return nil }
        let candidate = String(afterPrefix[..<dotIdx])
        guard candidate.count == 8 else { return nil }
        guard candidate.allSatisfy({ $0.isHexDigit }) else { return nil }
        return candidate
    }

    // MARK: - 加密 QEMU clone (D9 = 等价复制 + 同密码)

    /// 加密 QEMU VM clone. 不变量: master KEK / sub keys 不变 (salt + 密码不变 → 同 PBKDF2);
    /// LUKS qcow2 + swtpm state 字节复制仍可解; config.yaml.enc 解密改字段后用源 sub.config 重加密;
    /// routing JSON 仅改 vmId.
    private static func cloneEncryptedQEMU(sourceBundle: URL,
                                            targetBundle: URL,
                                            options: Options,
                                            password: String) throws -> Result {
        let fm = FileManager.default

        Self.log.info("clone start (encrypted qemu): \(sourceBundle.lastPathComponent, privacy: .public) → \(targetBundle.lastPathComponent, privacy: .public)")

        // 1. unlock 源 → 拿 sub keys + config (handle 持有 master KEK 派生子 keys 在内存)
        let handle = try EncryptedBundleIO.unlock(bundlePath: sourceBundle, password: password)
        defer { try? handle.close() }
        guard let subKeys = handle.qemuSubKeys else {
            throw HVMError.encryption(.parseFailed(reason: "unlock 未返子 keys"))
        }
        var config = handle.config

        var renamed: [String: String] = [:]
        let newID = UUID()

        do {
            // 2. 目标 bundle 骨架
            try fm.createDirectory(at: targetBundle, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: BundleLayout.disksDir(targetBundle),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])

            // 3. 主盘: 文件名不变, 字节复制 (LUKS header + ciphertext 一起)
            guard let mainDisk = config.disks.first(where: { $0.role == .main }) else {
                throw HVMError.config(.missingField(name: "disks 中无 role=main 的盘"))
            }
            try cloneFile(from: sourceBundle.appendingPathComponent(mainDisk.path),
                          to: targetBundle.appendingPathComponent(mainDisk.path))

            // 4. 数据盘: uuid8 重生 + 改 DiskSpec.path (LUKS header 不依赖文件名 → 字节复制即可解)
            for i in config.disks.indices where config.disks[i].role == .data {
                let oldDisk = config.disks[i]
                let oldName = (oldDisk.path as NSString).lastPathComponent
                let oldUUID8 = extractDataDiskUUID8(oldName)
                let newUUID8 = DiskFactory.newDataDiskUUID8()
                let newName = BundleLayout.dataDiskFileName(uuid8: newUUID8, engine: config.engine)
                let newRel = "\(BundleLayout.disksDirName)/\(newName)"
                try cloneFile(from: sourceBundle.appendingPathComponent(oldDisk.path),
                              to: targetBundle.appendingPathComponent(newRel))
                config.disks[i].path = newRel
                if let old = oldUUID8 {
                    renamed[old] = newUUID8
                }
            }

            // 5. nvram (LUKS qcow2 efi-vars) / tpm (swtpm-key 加密 permall) / auxiliary
            //    全部字节复制. master KEK 不变 → 同 sub keys 能解.
            try cloneIfExists(name: BundleLayout.nvramDirName, from: sourceBundle, to: targetBundle)
            try cloneIfExists(name: "tpm", from: sourceBundle, to: targetBundle)
            try cloneIfExists(name: BundleLayout.auxiliaryDirName, from: sourceBundle, to: targetBundle)

            // 6. 重生身份字段 (跟明文路径一致)
            config.id = newID
            config.displayName = options.newDisplayName
            config.createdAt = Date()
            if !options.keepMACAddresses {
                for i in config.networks.indices {
                    config.networks[i].macAddress = MACAddressGenerator.random()
                }
            }

            // 7. logs/ 空目录
            try fm.createDirectory(at: BundleLayout.logsDir(targetBundle),
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])

            // 8. config.yaml.enc: 用源 sub.config 重新加密写入目标 bundle
            //    (master KEK 不变 → 用户用源密码可解目标 .enc)
            try EncryptedConfigIO.save(config: config,
                                        to: targetBundle,
                                        key: subKeys.config)

            // 9. routing JSON: 读源 → 改 vmId + displayName → 写目标. salt/iter/scheme 不动.
            let srcRouting = RoutingJSON.locationForQemuBundle(sourceBundle)
            var routing = try RoutingJSON.read(from: srcRouting)
            routing.vmId = newID
            routing.displayName = options.newDisplayName
            let dstRouting = RoutingJSON.locationForQemuBundle(targetBundle)
            try RoutingJSON.write(routing, to: dstRouting)
        } catch {
            // 任意一步失败 → 清掉目标残留
            try? fm.removeItem(at: targetBundle)
            throw error
        }

        Self.log.info("clone done (encrypted qemu): \(sourceBundle.lastPathComponent, privacy: .public) → \(targetBundle.lastPathComponent, privacy: .public) newID=\(newID.uuidString, privacy: .public) renamedDataDisks=\(renamed.count)")

        return Result(sourceBundle: sourceBundle,
                      targetBundle: targetBundle,
                      newID: newID,
                      renamedDataDiskUUID8s: renamed)
    }
}
