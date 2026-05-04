// BootFromDiskCommand.swift
// hvm-cli boot-from-disk — 切 config.bootFromDiskOnly=true, 下次启动不挂 ISO

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

struct BootFromDiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot-from-disk",
        abstract: "标记 bundle 为只从硬盘启动 (安装完成后执行)"
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
            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            config.bootFromDiskOnly = true
            try EncryptedConfigEditor.save(config, session: session)

            switch format {
            case .human: print("✔ 已切换为仅从硬盘启动")
            case .json:  printJSON(["ok": "true", "bootFromDiskOnly": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
