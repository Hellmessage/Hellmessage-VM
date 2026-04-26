// StartCommand.swift
// hvm-cli start — 后台拉起 VMHost (HVM.app --host-mode-bundle), 立即返回

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动 VM (后台, 立即返回)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)

            // 若已运行 (锁被占), 拒绝
            if BundleLock.isBusy(bundleURL: bundleURL) {
                let holder = BundleLock.inspect(bundleURL: bundleURL)
                throw HVMError.bundle(.busy(
                    pid: holder?.pid ?? 0,
                    holderMode: holder?.mode ?? "unknown"
                ))
            }

            // 简单载入校验 (能读出 config, 主盘存在)
            let config = try BundleIO.load(from: bundleURL)

            let pid = try HostLauncher.launch(bundleURL: bundleURL)
            let logDir = HVMPaths.vmLogsDir(displayName: config.displayName, id: config.id).path

            switch format {
            case .human:
                print("✔ 已启动 VMHost (pid=\(pid))")
                print("  日志: \(logDir)")
                print("  查看状态: hvm-cli status \(vm)")
            case .json:
                printJSON([
                    "ok": "true",
                    "hostPid": "\(pid)",
                    "bundlePath": bundleURL.path,
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
