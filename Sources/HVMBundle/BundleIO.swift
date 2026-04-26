// HVMBundle/BundleIO.swift
// .hvmz bundle 的创建 / 加载 / 原子写入
// 布局规范见 docs/VM_BUNDLE.md

import Foundation
import HVMCore

public enum BundleIO {
    private static let log = HVMLog.logger("bundle.io")

    /// 创建一个全新的 .hvmz 目录, 写入初始 config.json 及子目录骨架.
    /// 若目标已存在 (哪怕是空目录) 也拒绝, 避免意外覆盖.
    public static func create(at bundleURL: URL, config: VMConfig) throws {
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
            case .linux:
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

    /// 读取 bundle 的 config.json 并校验 schema + 基本字段合法性.
    /// schemaVersion 比当前低 → 走 ConfigMigrator 升级链 (v1→v2→...→current);
    /// schemaVersion 比当前高 → 抛 invalidSchema 让用户升 HVM.
    public static func load(from bundleURL: URL) throws -> VMConfig {
        let fm = FileManager.default
        let configURL = BundleLayout.configURL(bundleURL)
        guard fm.fileExists(atPath: configURL.path) else {
            throw HVMError.bundle(.notFound(path: bundleURL.path))
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: error.localizedDescription, path: configURL.path))
        }

        // Step 1: 只解析 schemaVersion, 决定后续走 migrate 还是直接 decode current
        let envelope: _SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(_SchemaEnvelope.self, from: data)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "无法读取 schemaVersion: \(error)", path: configURL.path))
        }

        if envelope.schemaVersion > VMConfig.currentSchemaVersion {
            throw HVMError.bundle(.invalidSchema(
                version: envelope.schemaVersion,
                expected: VMConfig.currentSchemaVersion
            ))
        }

        // Step 2: 老 schema → 走升级链拿到当前版本的 JSON, 再 decode.
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let config: VMConfig
        do {
            config = try decoder.decode(VMConfig.self, from: upgradedData)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "\(error)", path: configURL.path))
        }

        // 主盘存在
        if let main = config.disks.first(where: { $0.role == .main }) {
            let mainURL = bundleURL.appendingPathComponent(main.path)
            guard fm.fileExists(atPath: mainURL.path) else {
                throw HVMError.bundle(.primaryDiskMissing(path: mainURL.path))
            }
        } else {
            throw HVMError.bundle(.primaryDiskMissing(path: BundleLayout.mainDiskURL(bundleURL).path))
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

    /// 原子写入 config.json: 先写 .tmp, 再 rename
    public static func save(config: VMConfig, to bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw HVMError.bundle(.writeFailed(reason: "encode: \(error)", path: BundleLayout.configURL(bundleURL).path))
        }

        let target = BundleLayout.configURL(bundleURL)
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(BundleLayout.configFileName).tmp")

        do {
            try data.write(to: tmp, options: .atomic)
            // 原子替换 (macOS 上 rename(2) 同卷保证原子)
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
