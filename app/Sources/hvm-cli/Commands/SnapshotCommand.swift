// SnapshotCommand.swift
// hvm-cli snapshot — APFS clonefile 整体快照 (磁盘 + config).
// 必须 VM stopped (running 时 disk 在写, snapshot 不一致).
//
// 实现见 HVMStorage/SnapshotManager.swift.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMStorage

struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "VM 整体快照 (磁盘 + config) — 基于 APFS clonefile",
        subcommands: [
            SnapshotCreateCommand.self,
            SnapshotListCommand.self,
            SnapshotRestoreCommand.self,
            SnapshotDeleteCommand.self,
        ]
    )
}

struct SnapshotCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "创建 snapshot (clonefile, 几乎零空间). 必须 VM stopped"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "snapshot 名 (字母/数字/-/_/., 1-64 字符)")
    var name: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            try SnapshotManager.create(bundleURL: bundleURL, name: name)
            switch format {
            case .human: print("✔ snapshot \(name) 已创建")
            case .json:  printJSON(["ok": "true", "name": name])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

struct SnapshotListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出 VM 所有 snapshot (按时间倒序)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let infos = SnapshotManager.list(bundleURL: bundleURL)
            switch format {
            case .json:
                let rows = infos.map { ["name": $0.name, "createdAt": ISO8601DateFormatter().string(from: $0.createdAt)] }
                printJSON(rows)
            case .human:
                if infos.isEmpty {
                    print("(无 snapshot)")
                    return
                }
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                print("NAME                              CREATED")
                for i in infos {
                    print("\(i.name.padding(toLength: 34, withPad: " ", startingAt: 0))\(df.string(from: i.createdAt))")
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

struct SnapshotRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "把 VM 还原到 snapshot. 必须 VM stopped. 当前 disks/* 和 config 会被覆盖"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "snapshot 名")
    var name: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            try SnapshotManager.restore(bundleURL: bundleURL, name: name)
            switch format {
            case .human: print("✔ 已还原到 snapshot \(name)")
            case .json:  printJSON(["ok": "true", "name": name])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

struct SnapshotDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "删除指定 snapshot"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "snapshot 名")
    var name: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            try SnapshotManager.delete(bundleURL: bundleURL, name: name)
            switch format {
            case .human: print("✔ 已删除 snapshot \(name)")
            case .json:  printJSON(["ok": "true", "name": name])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
