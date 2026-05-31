// HVMStorage/SnapshotManager.swift
// 基于 APFS clonefile(2) 的 VM 整体快照: disks/* + config.yaml(.enc) + nvram/ + tpm/ + meta.json.
// clonefile 是 COW, 几乎零空间 + 瞬间完成. 布局: <bundle>/snapshots/<name>/{disks/,nvram/,tpm/,config.*,meta.json}.
// nvram/ (EFI vars/BootOrder) + tpm/ (swtpm 状态) 一并快照, 否则 Windows 恢复后 EFI/BitLocker 失配.
//
// 加密 VM: clonefile 字节级 COW 复制 LUKS qcow2 / config.yaml.enc / nvram(.luks) / tpm 不解密
// (snapshot 不需密码); master KEK 不变, restore 后用源密码可解 (rekey 后 restore 须用旧密码).
//
// 限制: VM 必须 stopped (running 时 disk 在写则不一致); clonefile 要求 src/dst 同 APFS volume
// (bundle 内满足); restore 非原子 (中途 crash 可能半旧半新, 但 snapshot 仍完整可重 restore).

import Foundation
import Darwin
import HVMBundle
import HVMCore

/// clonefile(2) 直接绑定. flags=0 = 默认 owner copy.
@_silgen_name("clonefile")
private func _hvmClonefile(_ src: UnsafePointer<CChar>,
                            _ dst: UnsafePointer<CChar>,
                            _ flags: UInt32) -> Int32

public enum SnapshotManager {
    private static let log = HVMLog.logger("storage.snapshot")

    public struct Info: Sendable {
        public let name: String
        public let createdAt: Date
        public let path: URL
    }

    private struct MetaFile: Codable {
        let name: String
        let createdAt: Date
    }

    /// 创建 snapshot. 已存在同名则抛错.
    public static func create(bundleURL: URL, name: String) throws {
        try validateName(name)
        let snapDir = BundleLayout.snapshotDir(bundleURL, name: name)
        if FileManager.default.fileExists(atPath: snapDir.path) {
            throw HVMError.storage(.diskAlreadyExists(path: snapDir.path))
        }
        Self.log.info("snapshot create: \(bundleURL.lastPathComponent, privacy: .public) name=\(name, privacy: .public)")
        let snapDisks = snapDir.appendingPathComponent(BundleLayout.disksDirName)
        try FileManager.default.createDirectory(at: snapDisks, withIntermediateDirectories: true)

        // clone 所有磁盘 (.img + .qcow2; 加密 LUKS qcow2 字节复制透明)
        let bundleDisks = BundleLayout.disksDir(bundleURL)
        let imgs = (try? FileManager.default.contentsOfDirectory(atPath: bundleDisks.path)) ?? []
        for n in imgs where Self.isDiskFile(n) {
            try cloneFile(from: bundleDisks.appendingPathComponent(n),
                          to: snapDisks.appendingPathComponent(n))
        }

        // config 按加密形态择一 copy: config.yaml 或 config.yaml.enc
        let (cfgSrc, cfgName) = try locateBundleConfig(bundleURL: bundleURL)
        let cfgDst = snapDir.appendingPathComponent(cfgName)
        try FileManager.default.copyItem(at: cfgSrc, to: cfgDst)

        // nvram/ (EFI vars/BootOrder) + tpm/ (swtpm 状态) 整目录 clone — 不带会让 Windows
        // 恢复后 EFI 启动项错乱 / BitLocker(TPM 封印) 失效. clonefile 支持目录递归 COW.
        try cloneDirIfExists(BundleLayout.nvramDir(bundleURL),
                             to: snapDir.appendingPathComponent(BundleLayout.nvramDirName))
        try cloneDirIfExists(BundleLayout.tpmStateDir(bundleURL),
                             to: snapDir.appendingPathComponent("tpm"))

        // meta
        let meta = MetaFile(name: name, createdAt: Date())
        let metaData = try JSONEncoder().encode(meta)
        try metaData.write(to: snapDir.appendingPathComponent("meta.json"))
    }

    /// 列出所有 snapshot, 按 createdAt 倒序.
    public static func list(bundleURL: URL) -> [Info] {
        let snapsDir = BundleLayout.snapshotsDir(bundleURL)
        guard FileManager.default.fileExists(atPath: snapsDir.path) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapsDir.path)) ?? []
        return names.compactMap { name -> Info? in
            let snapDir = snapsDir.appendingPathComponent(name)
            let metaURL = snapDir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(MetaFile.self, from: data) else {
                return nil
            }
            return Info(name: meta.name, createdAt: meta.createdAt, path: snapDir)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 把 snapshot 还原到 bundle: 删 bundle/disks/*.img + clone snapshot 的 → bundle/disks/.
    /// 同时把 config.json 替换. 非原子: 中途 crash 可能半旧半新, 但 snapshot 仍完整可重 restore.
    public static func restore(bundleURL: URL, name: String) throws {
        let snapDir = BundleLayout.snapshotDir(bundleURL, name: name)
        guard FileManager.default.fileExists(atPath: snapDir.path) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: snapDir.path))
        }
        Self.log.warning("snapshot restore: \(bundleURL.lastPathComponent, privacy: .public) name=\(name, privacy: .public) (覆盖当前 disks + config)")
        let snapDisks = snapDir.appendingPathComponent(BundleLayout.disksDirName)
        let bundleDisks = BundleLayout.disksDir(bundleURL)

        // 1. 把 snapshot 里的磁盘先 clone 到 bundle 内的 .restore-tmp/ (跨步骤可见性 + 失败可清理)
        let tmpName = ".restore-tmp-\(UUID().uuidString.prefix(8))"
        let tmpDir = bundleURL.appendingPathComponent(tmpName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: false)
        let snapNames = (try? FileManager.default.contentsOfDirectory(atPath: snapDisks.path)) ?? []
        let snapDisksList = snapNames.filter { Self.isDiskFile($0) }
        do {
            for n in snapDisksList {
                try cloneFile(from: snapDisks.appendingPathComponent(n),
                              to: tmpDir.appendingPathComponent(n))
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpDir)
            throw error
        }

        // 2. 删 bundle/disks/ 下现有磁盘 (snapshot 是 ground truth)
        let curNames = (try? FileManager.default.contentsOfDirectory(atPath: bundleDisks.path)) ?? []
        for n in curNames where Self.isDiskFile(n) {
            try? FileManager.default.removeItem(at: bundleDisks.appendingPathComponent(n))
        }

        // 3. 把 tmp 里的磁盘移到 bundle/disks/
        for n in snapDisksList {
            try FileManager.default.moveItem(at: tmpDir.appendingPathComponent(n),
                                              to: bundleDisks.appendingPathComponent(n))
        }
        try? FileManager.default.removeItem(at: tmpDir)

        // 4. config atomic replace. snapshot 内可能是 config.yaml 或 config.yaml.enc.
        // bundle 内同样两种之一 (互斥). 先把 bundle 现有的两种都清, 再 mv snapshot 的过来.
        try restoreConfig(snapDir: snapDir, bundleURL: bundleURL)

        // 5. nvram/ + tpm/ 还原 (老快照无这两目录 → 跳过, 保留当前; 向后兼容).
        try restoreDirIfPresent(snapDir.appendingPathComponent(BundleLayout.nvramDirName),
                                to: BundleLayout.nvramDir(bundleURL))
        try restoreDirIfPresent(snapDir.appendingPathComponent("tpm"),
                                to: BundleLayout.tpmStateDir(bundleURL))
    }

    /// 源目录存在才 clonefile 整目录到 dst (dst 必须不存在). 用于 create 阶段 nvram/tpm.
    private static func cloneDirIfExists(_ src: URL, to dst: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        try cloneFile(from: src, to: dst)
    }

    /// snapshot 内有该目录才还原: 删 bundle 现有 + clonefile snapshot 的过来 (老快照无 → 保留当前).
    private static func restoreDirIfPresent(_ snapSubdir: URL, to bundleSubdir: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: snapSubdir.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        try? FileManager.default.removeItem(at: bundleSubdir)
        try cloneFile(from: snapSubdir, to: bundleSubdir)
    }

    // MARK: - 加密-aware config helpers

    /// 找 bundle 现存的 config 文件 (明文 config.yaml 或加密 config.yaml.enc).
    /// 两种都不存在 → throw .bundle(.notFound). 两种同存 (异常态) → 走加密优先.
    private static func locateBundleConfig(bundleURL: URL) throws -> (URL, String) {
        let plain = bundleURL.appendingPathComponent(BundleLayout.configFileName)
        let enc   = bundleURL.appendingPathComponent("config.yaml.enc")
        let fm = FileManager.default
        if fm.fileExists(atPath: enc.path) {
            return (enc, "config.yaml.enc")
        }
        if fm.fileExists(atPath: plain.path) {
            return (plain, BundleLayout.configFileName)
        }
        throw HVMError.bundle(.notFound(path: plain.path))
    }

    /// snapshot restore 期 config 替换: 把 bundle 现有的 config.yaml + config.yaml.enc 都清,
    /// 把 snapshot 里有的那个 mv 过来 (atomic via tmp + replaceItemAt).
    private static func restoreConfig(snapDir: URL, bundleURL: URL) throws {
        let snapPlain = snapDir.appendingPathComponent(BundleLayout.configFileName)
        let snapEnc   = snapDir.appendingPathComponent("config.yaml.enc")
        let fm = FileManager.default

        let (snapCfgSrc, cfgName): (URL, String)
        if fm.fileExists(atPath: snapEnc.path) {
            (snapCfgSrc, cfgName) = (snapEnc, "config.yaml.enc")
        } else if fm.fileExists(atPath: snapPlain.path) {
            (snapCfgSrc, cfgName) = (snapPlain, BundleLayout.configFileName)
        } else {
            throw HVMError.bundle(.notFound(path: snapPlain.path))
        }

        let cfgTmp = bundleURL.appendingPathComponent(".config-restore-\(UUID().uuidString.prefix(8)).tmp")
        try fm.copyItem(at: snapCfgSrc, to: cfgTmp)

        // 清 bundle 现有 config (两种都清, snapshot 决定恢复后是哪一种)
        let bundlePlain = bundleURL.appendingPathComponent(BundleLayout.configFileName)
        let bundleEnc   = bundleURL.appendingPathComponent("config.yaml.enc")
        try? fm.removeItem(at: bundlePlain)
        try? fm.removeItem(at: bundleEnc)

        // mv tmp → bundle/<cfgName>
        try fm.moveItem(at: cfgTmp, to: bundleURL.appendingPathComponent(cfgName))
    }

    /// 磁盘文件名识别: .img (raw) 或 .qcow2 (含 LUKS 加密).
    private static func isDiskFile(_ name: String) -> Bool {
        name.hasSuffix(".img") || name.hasSuffix(".qcow2")
    }

    public static func delete(bundleURL: URL, name: String) throws {
        Self.log.info("snapshot delete: \(bundleURL.lastPathComponent, privacy: .public) name=\(name, privacy: .public)")
        let snapDir = BundleLayout.snapshotDir(bundleURL, name: name)
        guard FileManager.default.fileExists(atPath: snapDir.path) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: snapDir.path))
        }
        try FileManager.default.removeItem(at: snapDir)
    }

    // MARK: - 内部

    /// clonefile 包装. flags=0 即 owner copy (跟 cp -c 等价).
    public static func cloneFile(from src: URL, to dst: URL) throws {
        let result = src.path.withCString { srcPath in
            dst.path.withCString { dstPath in
                _hvmClonefile(srcPath, dstPath, 0)
            }
        }
        if result != 0 {
            throw HVMError.storage(.ioError(errno: errno, path: dst.path))
        }
    }

    /// snapshot name 校验: 不允许 / .. 控制字符等. 走白名单: 字母/数字/-/_/.
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 64 else {
            throw HVMError.config(.invalidEnum(field: "snapshot.name",
                                                raw: name,
                                                allowed: ["1-64 字符"]))
        }
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw HVMError.config(.invalidEnum(field: "snapshot.name",
                                                raw: name,
                                                allowed: ["alphanumeric / - / _ / ."]))
        }
        guard name != "." && name != ".." else {
            throw HVMError.config(.invalidEnum(field: "snapshot.name",
                                                raw: name,
                                                allowed: ["不能是 . 或 .."]))
        }
    }
}
