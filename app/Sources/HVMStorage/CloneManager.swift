// HVMStorage/CloneManager.swift
// 整 VM 克隆: APFS clonefile(2) 复制磁盘 + nvram/tpm/auxiliary/meta + 重生身份字段.
// 设计稿见 docs/v3/CLONE.md.
//
// 重生策略:
//   - config.id            → UUID()
//   - config.displayName   → options.newDisplayName
//   - config.createdAt     → Date()
//   - 数据盘 data-<uuid8>.* → uuid8 重生 + 同步改 DiskSpec.path
//   - networks[].mac       → MACAddressGenerator.random() (默认; keepMACAddresses=true 保留)
//   - auxiliary/machine-identifier (macOS guest) → 新 VZMacMachineIdentifier()
//
// 保留:
//   - 主盘 os.{img,qcow2} 文件名 (主盘命名按 engine 是固定值, 不带 uuid)
//   - 磁盘内容 (APFS clonefile, COW 直到首次写)
//   - auxiliary/aux-storage + auxiliary/hardware-model (macOS, 与 IPSW 装机配对, 不可改)
//   - nvram/efi-vars.fd (EFI BootOrder; 重置 = guest 进 EFI Shell)
//   - tpm/* (Win11 swtpm state; 重置 = BitLocker 永久失效)
//
// 不带:
//   - .lock (目标首次启动自然创建)
//   - logs/ (新 VM 一身轻; logs/ 子目录预创建空目录, ConsoleBridge 启动时直接写)
//   - .unattend-stage/, unattend.iso (Windows 装机产物, 启动时按需重新生成)
//   - snapshots/ (默认; --include-snapshots 可选)
//
// 前置约束:
//   - 源 VM 必须 stopped — 函数内部抢 .edit lock 排他, 已被 .runtime 持有时抛 .busy
//   - 源 + 目标父目录必须同 APFS 卷 — clonefile(2) 跨卷 EXDEV. 提前 stat st_dev 探测
//   - 目标 bundle 路径不能存在
//   - 失败时清理目标残留 (CloneManager 不留 partial bundle)

import Foundation
import Darwin
@preconcurrency import Virtualization
import HVMCore
import HVMBundle
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
        /// true = 复制 snapshots/ 整目录到目标
        public var includeSnapshots: Bool

        public init(newDisplayName: String,
                    targetParentDir: URL? = nil,
                    keepMACAddresses: Bool = false,
                    includeSnapshots: Bool = false) {
            self.newDisplayName = newDisplayName
            self.targetParentDir = targetParentDir
            self.keepMACAddresses = keepMACAddresses
            self.includeSnapshots = includeSnapshots
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

        // 加载源 config (走 schema 升级链 + 校验)
        var config = try BundleIO.load(from: sourceBundle)

        Self.log.info("clone start: \(sourceBundle.lastPathComponent, privacy: .public) → \(targetBundle.lastPathComponent, privacy: .public)")

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

            // macOS guest: 重生 machine-identifier (覆盖刚 clone 进来的字节). hardware-model 保留.
            if config.guestOS == .macOS {
                let auxDir = BundleLayout.auxiliaryDir(targetBundle)
                let machineIDURL = auxDir.appendingPathComponent(BundleLayout.machineIdentifier)
                // 如果源原本没有 auxiliary 目录 (异常 bundle), 兜底建出来
                if !fm.fileExists(atPath: auxDir.path) {
                    try fm.createDirectory(at: auxDir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o755])
                }
                let newMachineID = VZMacMachineIdentifier()
                do {
                    try newMachineID.dataRepresentation.write(to: machineIDURL, options: .atomic)
                } catch {
                    throw HVMError.bundle(.writeFailed(reason: "machine-identifier 写入失败: \(error)",
                                                       path: machineIDURL.path))
                }
            }

            // 可选 snapshots
            if options.includeSnapshots {
                try cloneIfExists(name: BundleLayout.snapshotsDirName,
                                  from: sourceBundle, to: targetBundle)
            }

            // logs/ 空目录: ConsoleBridge / QemuConsoleBridge 启动时写
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

    /// SnapshotManager.cloneFile 的本模块别名. 复用同一份 clonefile(2) 包装,
    /// 不在 HVMStorage 内重复实现. flags=0 = owner copy, 等价 cp -c.
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
}
