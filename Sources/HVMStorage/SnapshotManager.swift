// HVMStorage/SnapshotManager.swift
// 基于 APFS clonefile(2) 的 VM 整体快照: disks/* + config.json.
// clonefile 是 APFS copy-on-write, 几乎零空间 + 瞬间完成 (10GB 主盘也是 ms 级).
//
// 布局:
//   <bundle>/snapshots/<name>/disks/main.img      (clone of bundle/disks/main.img)
//   <bundle>/snapshots/<name>/disks/data-*.img    (clone 所有数据盘)
//   <bundle>/snapshots/<name>/config.json         (config 副本, 普通 copy)
//   <bundle>/snapshots/<name>/meta.json           ({createdAt, name})
//
// 限制:
//   - VM 必须 stopped (running 时 disk 在写, snapshot 不一致)
//   - clonefile 要求 src/dst 在同一 APFS volume, bundle 内的一切都满足
//   - restore 是非原子的: 中途 crash 可能让 bundle 处于半新半旧状态; 但 snapshot 仍完整,
//     可以再 restore 一次自愈

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
        let snapDisks = snapDir.appendingPathComponent(BundleLayout.disksDirName)
        try FileManager.default.createDirectory(at: snapDisks, withIntermediateDirectories: true)

        // clone 所有 .img 磁盘 (包含 main + data-*)
        let bundleDisks = BundleLayout.disksDir(bundleURL)
        let imgs = (try? FileManager.default.contentsOfDirectory(atPath: bundleDisks.path)) ?? []
        for n in imgs where n.hasSuffix(".img") {
            try cloneFile(from: bundleDisks.appendingPathComponent(n),
                          to: snapDisks.appendingPathComponent(n))
        }

        // config.json 普通 copy (文件小)
        let cfgSrc = BundleLayout.configURL(bundleURL)
        let cfgDst = snapDir.appendingPathComponent(BundleLayout.configFileName)
        try FileManager.default.copyItem(at: cfgSrc, to: cfgDst)

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
        let snapDisks = snapDir.appendingPathComponent(BundleLayout.disksDirName)
        let bundleDisks = BundleLayout.disksDir(bundleURL)

        // 1. 把 snapshot 里的 .img 先 clone 到 bundle 内的 .restore-tmp/ (跨步骤可见性 + 失败可清理)
        let tmpName = ".restore-tmp-\(UUID().uuidString.prefix(8))"
        let tmpDir = bundleURL.appendingPathComponent(tmpName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: false)
        let snapNames = (try? FileManager.default.contentsOfDirectory(atPath: snapDisks.path)) ?? []
        let snapImgs = snapNames.filter { $0.hasSuffix(".img") }
        do {
            for n in snapImgs {
                try cloneFile(from: snapDisks.appendingPathComponent(n),
                              to: tmpDir.appendingPathComponent(n))
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpDir)
            throw error
        }

        // 2. 删 bundle/disks/ 下现有 .img (snapshot 是 ground truth)
        let curNames = (try? FileManager.default.contentsOfDirectory(atPath: bundleDisks.path)) ?? []
        for n in curNames where n.hasSuffix(".img") {
            try? FileManager.default.removeItem(at: bundleDisks.appendingPathComponent(n))
        }

        // 3. 把 tmp 里的 .img 移到 bundle/disks/
        for n in snapImgs {
            try FileManager.default.moveItem(at: tmpDir.appendingPathComponent(n),
                                              to: bundleDisks.appendingPathComponent(n))
        }
        try? FileManager.default.removeItem(at: tmpDir)

        // 4. config.json atomic replace (replaceItemAt 走 rename, 同卷上原子)
        let cfgSrc = snapDir.appendingPathComponent(BundleLayout.configFileName)
        let cfgDst = BundleLayout.configURL(bundleURL)
        let cfgTmp = bundleURL.appendingPathComponent(".config-restore-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.copyItem(at: cfgSrc, to: cfgTmp)
        _ = try FileManager.default.replaceItemAt(cfgDst, withItemAt: cfgTmp)
    }

    public static func delete(bundleURL: URL, name: String) throws {
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
