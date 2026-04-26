// HVMBundle/BundleIO.swift
// .hvmz bundle 的创建 / 加载 / 原子写入. config 落盘格式 = YAML (Yams).
// 布局规范见 docs/VM_BUNDLE.md

import Foundation
import HVMCore
import Yams

public enum BundleIO {
    private static let log = HVMLog.logger("bundle.io")

    /// 创建一个全新的 .hvmz 目录, 写入初始 config.yaml 及子目录骨架.
    /// 若目标已存在 (哪怕是空目录) 也拒绝, 避免意外覆盖.
    public static func create(at bundleURL: URL, config: VMConfig) throws {
        try config.validate()
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            throw HVMError.bundle(.alreadyExists(path: bundleURL.path))
        }
        Self.log.info("create bundle: \(bundleURL.lastPathComponent, privacy: .public) os=\(config.guestOS.rawValue, privacy: .public) cpu=\(config.cpuCount) mem=\(config.memoryMiB)MiB")

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: BundleLayout.disksDir(bundleURL), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: BundleLayout.logsDir(bundleURL), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: BundleLayout.metaDir(bundleURL), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755])
            switch config.guestOS {
            case .linux, .windows:
                try fm.createDirectory(at: BundleLayout.nvramDir(bundleURL), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755])
            case .macOS:
                try fm.createDirectory(at: BundleLayout.auxiliaryDir(bundleURL), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o755])
            }
        } catch {
            throw HVMError.bundle(.writeFailed(reason: error.localizedDescription, path: bundleURL.path))
        }

        try save(config: config, to: bundleURL)
    }

    /// 读取 bundle 的 config.yaml. 老 .json 已断兼容: 检测到 config.json 直接报错.
    /// schemaVersion 比当前低 → 走 ConfigMigrator 升级 (v2 起内部都是 yaml);
    /// schemaVersion 比当前高 → 抛 invalidSchema 让用户升 HVM.
    public static func load(from bundleURL: URL) throws -> VMConfig {
        let fm = FileManager.default
        let configURL = BundleLayout.configURL(bundleURL)

        // B3 断老兼容: 没有 config.yaml 但有 config.json → 老 v1 bundle, 直接报错
        if !fm.fileExists(atPath: configURL.path) {
            let legacyURL = BundleLayout.legacyConfigURL(bundleURL)
            if fm.fileExists(atPath: legacyURL.path) {
                throw HVMError.bundle(.parseFailed(
                    reason: "检测到老 schema config.json (v1, JSON). 当前版本仅支持 config.yaml (v2+); 请重新创建 VM 或手动迁移配置.",
                    path: legacyURL.path
                ))
            }
            throw HVMError.bundle(.notFound(path: bundleURL.path))
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: error.localizedDescription, path: configURL.path))
        }

        // Step 1: 只解析 schemaVersion (YAML), 决定后续走 migrate 还是直接 decode current
        let envelope: _SchemaEnvelope
        do {
            envelope = try YAMLDecoder().decode(_SchemaEnvelope.self, from: data)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "无法读取 schemaVersion: \(error)", path: configURL.path))
        }

        if envelope.schemaVersion > VMConfig.currentSchemaVersion {
            throw HVMError.bundle(.invalidSchema(
                version: envelope.schemaVersion,
                expected: VMConfig.currentSchemaVersion
            ))
        }

        // Step 2: 老 schema → 走升级链拿到当前版本的 yaml data, 再 decode.
        let upgradedData: Data
        if envelope.schemaVersion < VMConfig.currentSchemaVersion {
            Self.log.info("bundle 走 schema 迁移: \(bundleURL.lastPathComponent, privacy: .public) v\(envelope.schemaVersion) → v\(VMConfig.currentSchemaVersion)")
            do {
                upgradedData = try ConfigMigrator.migrate(
                    data: data,
                    from: envelope.schemaVersion,
                    to: VMConfig.currentSchemaVersion
                )
            } catch let e as HVMError {
                throw e
            } catch {
                throw HVMError.bundle(.parseFailed(reason: "schema 迁移失败: \(error)", path: configURL.path))
            }
        } else {
            upgradedData = data
        }

        let config: VMConfig
        do {
            config = try YAMLDecoder().decode(VMConfig.self, from: upgradedData)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "\(error)", path: configURL.path))
        }

        // 主盘存在 + 路径走 config.disks (不再依赖 BundleLayout 常量推断)
        guard let main = config.disks.first(where: { $0.role == .main }) else {
            throw HVMError.config(.missingField(name: "disks 中无 role=main 的盘"))
        }
        let mainURL = bundleURL.appendingPathComponent(main.path)
        guard fm.fileExists(atPath: mainURL.path) else {
            throw HVMError.bundle(.primaryDiskMissing(path: mainURL.path))
        }

        // 所有 disk 路径必须落在 disks/ 下
        for d in config.disks where !BundleLayout.isDiskPathInSandbox(d.path) {
            throw HVMError.bundle(.outsideSandbox(requestedPath: d.path))
        }

        // 主盘唯一
        let mainCount = config.disks.filter { $0.role == .main }.count
        if mainCount != 1 {
            throw HVMError.config(.duplicateRole(role: "main"))
        }

        return config
    }

    /// 原子写入 config.yaml: 先写 .tmp, 再 rename
    public static func save(config: VMConfig, to bundleURL: URL) throws {
        try config.validate()

        let encoder = YAMLEncoder()
        encoder.options.indent = 2
        encoder.options.sortKeys = true
        encoder.options.allowUnicode = true

        let yamlString: String
        do {
            yamlString = try encoder.encode(config)
        } catch {
            throw HVMError.bundle(.writeFailed(
                reason: "yaml encode: \(error)",
                path: BundleLayout.configURL(bundleURL).path
            ))
        }

        guard let data = yamlString.data(using: .utf8) else {
            throw HVMError.bundle(.writeFailed(
                reason: "utf8 encoding 失败",
                path: BundleLayout.configURL(bundleURL).path
            ))
        }

        let target = BundleLayout.configURL(bundleURL)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(BundleLayout.configFileName).tmp")

        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            throw HVMError.bundle(.writeFailed(reason: error.localizedDescription, path: target.path))
        }
    }
}

/// 仅解 schemaVersion 字段, 用于 load 时决定是否走 migration.
private struct _SchemaEnvelope: Decodable {
    let schemaVersion: Int
}
