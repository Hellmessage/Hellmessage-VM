// DiskCommand.swift
// hvm-cli disk — 管理 VM 磁盘 (list / add / resize / delete data).
// 所有操作要求 VM stopped (VZ 不支持热插拔 storage; 主盘 resize 也不安全).
//
// 命名规则 (CLAUDE.md 约束):
//   - 主盘:  disks/main.img,  id = "main"
//   - 数据盘: disks/data-<uuid8>.img, id = "<uuid8>"

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu
import HVMStorage

struct DiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "管理 VM 磁盘 (list / add / resize / delete)",
        subcommands: [
            DiskListCommand.self,
            DiskAddCommand.self,
            DiskResizeCommand.self,
            DiskDeleteCommand.self,
        ]
    )
}

// MARK: - 共享 helpers

private enum DiskHelpers {
    /// 在 config.disks 里按 id 找索引. 兼容老 .img 与新 .qcow2 数据盘.
    static func findDiskIndex(id: String, in config: VMConfig) -> Int? {
        if id == "main" {
            return config.disks.firstIndex { $0.role == .main }
        }
        let prefixImg   = "\(BundleLayout.disksDirName)/data-\(id).img"
        let prefixQcow2 = "\(BundleLayout.disksDirName)/data-\(id).qcow2"
        return config.disks.firstIndex {
            $0.role == .data && ($0.path == prefixImg || $0.path == prefixQcow2)
        }
    }

    /// data disk 的 id (uuid8 部分). 同时识别 .img / .qcow2.
    static func dataDiskID(path: String) -> String? {
        let prefix = "\(BundleLayout.disksDirName)/data-"
        guard path.hasPrefix(prefix) else { return nil }
        let stem = (path as NSString).deletingPathExtension
        guard stem.hasPrefix(prefix) else { return nil }
        return String(stem.dropFirst(prefix.count))
    }
}

// MARK: - list

struct DiskListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出 VM 所有磁盘"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let (config, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            let rows = config.disks.map { d -> [String: String] in
                let absURL = bundleURL.appendingPathComponent(d.path)
                let logical = (try? DiskFactory.logicalBytes(at: absURL)) ?? 0
                let actual  = (try? DiskFactory.actualBytes(at: absURL)) ?? 0
                let id = d.role == .main ? "main" : (DiskHelpers.dataDiskID(path: d.path) ?? "?")
                return [
                    "id":           id,
                    "role":         d.role.rawValue,
                    "path":         d.path,
                    "sizeGiB":      String(d.sizeGiB),
                    "logicalBytes": String(logical),
                    "actualBytes":  String(actual),
                ]
            }
            switch format {
            case .json:
                printJSON(rows)
            case .human:
                print("ID         ROLE   SIZE     ACTUAL    PATH")
                for r in rows {
                    let actualMB = (Double(r["actualBytes"] ?? "0") ?? 0) / 1024 / 1024
                    let sz = "\(r["sizeGiB"] ?? "?")gb".padding(toLength: 8, withPad: " ", startingAt: 0)
                    let ac = String(format: "%6.1fmb", actualMB)
                    print("\(r["id"]!.padding(toLength: 11, withPad: " ", startingAt: 0))\(r["role"]!.padding(toLength: 7, withPad: " ", startingAt: 0))\(sz) \(ac)  \(r["path"]!)")
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - add

struct DiskAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "加一块数据盘 (raw sparse). 必须 VM stopped"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "数据盘大小 (GiB)")
    var size: UInt64

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            guard size >= 1 else {
                throw HVMError.config(.missingField(name: "disk size 必须 >=1 GiB"))
            }
            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            let uuid8 = DiskFactory.newDataDiskUUID8()
            let diskFormat: DiskFormat = config.engine == .qemu ? .qcow2 : .raw
            let fileName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: config.engine)
            let relPath = "\(BundleLayout.disksDirName)/\(fileName)"
            let absURL = bundleURL.appendingPathComponent(relPath)

            if let subKeys = session.qemuSubKeys {
                // 加密 VM: 新数据盘走 LUKS qcow2 (与现有主盘 / 数据盘同样加密)
                guard diskFormat == .qcow2 else {
                    throw HVMError.config(.invalidEnum(
                        field: "engine", raw: config.engine.rawValue,
                        allowed: ["qemu (加密 VM 数据盘必须 qcow2)"]
                    ))
                }
                let qemuImg = try QemuPaths.qemuImgBinary()
                let sizeBytes = size * 1024 * 1024 * 1024
                try QcowLuksFactory.create(at: absURL,
                                            sizeBytes: sizeBytes,
                                            key: subKeys.qcow2Disk,
                                            qemuImg: qemuImg)
            } else {
                // 明文 VM: 原 DiskFactory 路径
                let qemuImg = diskFormat == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
                try DiskFactory.create(at: absURL, sizeGiB: size, format: diskFormat, qemuImg: qemuImg)
            }
            config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: size, format: diskFormat))
            try EncryptedConfigEditor.save(config, session: session)
            switch format {
            case .human:
                let suffix = session.isEncrypted ? " (LUKS 加密)" : ""
                print("✔ 已加数据盘 id=\(uuid8) size=\(size)gb path=\(relPath)\(suffix)")
            case .json:  printJSON(["ok": "true", "id": uuid8, "path": relPath, "sizeGiB": String(size),
                                     "encrypted": session.isEncrypted ? "true" : "false"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - resize

struct DiskResizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "扩容磁盘 (只能增大). 必须 VM stopped; guest 内还要 resize2fs / 分区工具"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "磁盘 id (默认 main; 数据盘填 uuid8)")
    var id: String = "main"

    @Option(name: .long, help: "新大小 (GiB), 必须 > 当前")
    var to: UInt64

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            guard let idx = DiskHelpers.findDiskIndex(id: id, in: config) else {
                throw HVMError.config(.missingField(name: "disk id=\(id) 未找到"))
            }
            let absURL = bundleURL.appendingPathComponent(config.disks[idx].path)
            let diskFormat = config.disks[idx].format

            if let subKeys = session.qemuSubKeys {
                // 加密 VM: LUKS qcow2 走 QcowLuksFactory.grow (传 key + qemu-img)
                guard diskFormat == .qcow2 else {
                    throw HVMError.config(.invalidEnum(
                        field: "disk.format", raw: diskFormat.rawValue,
                        allowed: ["qcow2 (加密 VM 主/数据盘必须 LUKS qcow2)"]
                    ))
                }
                let qemuImg = try QemuPaths.qemuImgBinary()
                let toBytes = to * 1024 * 1024 * 1024
                try QcowLuksFactory.grow(at: absURL,
                                          toBytes: toBytes,
                                          key: subKeys.qcow2Disk,
                                          qemuImg: qemuImg)
            } else {
                let qemuImg = diskFormat == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
                try DiskFactory.grow(at: absURL, toGiB: to, format: diskFormat, qemuImg: qemuImg)
            }
            config.disks[idx].sizeGiB = to
            try EncryptedConfigEditor.save(config, session: session)
            switch format {
            case .human: print("✔ disk id=\(id) 已扩容到 \(to)gb (host 侧). guest 内需 resize2fs / 分区工具")
            case .json:  printJSON(["ok": "true", "id": id, "sizeGiB": String(to),
                                     "encrypted": session.isEncrypted ? "true" : "false"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - delete

struct DiskDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "删除数据盘 (主盘禁删). 必须 VM stopped"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "数据盘 id (uuid8)")
    var id: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            guard id != "main" else {
                throw HVMError.config(.invalidEnum(field: "disk.id", raw: "main",
                                                    allowed: ["数据盘 uuid8"]))
            }
            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            guard let idx = DiskHelpers.findDiskIndex(id: id, in: config) else {
                throw HVMError.config(.missingField(name: "data disk id=\(id) 未找到"))
            }
            let absURL = bundleURL.appendingPathComponent(config.disks[idx].path)
            try DiskFactory.delete(at: absURL)
            config.disks.remove(at: idx)
            try EncryptedConfigEditor.save(config, session: session)
            switch format {
            case .human: print("✔ 已删除数据盘 id=\(id)")
            case .json:  printJSON(["ok": "true", "id": id])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
