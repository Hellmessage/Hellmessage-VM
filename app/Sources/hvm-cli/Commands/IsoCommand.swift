// IsoCommand.swift
// hvm-cli iso — 管理 VM 的安装 ISO. 必须 VM stopped (VZ 不支持热挂载 storage).
//
// macOS guest 走 IPSW + VZMacOSInstaller, 不挂 ISO. iso 子命令仅对 Linux guest 有效.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore

struct IsoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iso",
        abstract: "管理 VM 安装 ISO (仅 Linux guest)",
        subcommands: [IsoSelectCommand.self, IsoEjectCommand.self]
    )
}

struct IsoSelectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "指定/替换安装 ISO (会同时把 bootFromDiskOnly 关掉)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "ISO 绝对路径")
    var path: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: bundleURL)
            guard config.guestOS == .linux else {
                throw HVMError.config(.invalidEnum(field: "iso.guestOS",
                                                    raw: "\(config.guestOS)",
                                                    allowed: ["linux"]))
            }
            let absPath = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: absPath) else {
                throw HVMError.config(.missingField(name: "iso 文件不存在: \(absPath)"))
            }
            config.installerISO = absPath
            config.bootFromDiskOnly = false
            try BundleIO.save(config: config, to: bundleURL)
            switch format {
            case .human: print("✔ ISO 已设为 \(absPath); bootFromDiskOnly=false")
            case .json:  printJSON(["ok": "true", "installerISO": absPath])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

struct IsoEjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "弹出 ISO 并切到仅硬盘启动"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: bundleURL)
            guard config.guestOS == .linux else {
                throw HVMError.config(.invalidEnum(field: "iso.guestOS",
                                                    raw: "\(config.guestOS)",
                                                    allowed: ["linux"]))
            }
            config.installerISO = nil
            config.bootFromDiskOnly = true
            try BundleIO.save(config: config, to: bundleURL)
            switch format {
            case .human: print("✔ ISO 已弹出; bootFromDiskOnly=true")
            case .json:  printJSON(["ok": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
