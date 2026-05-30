// StopCommand.swift
// hvm-cli stop — 软关机 (发 ACPI shutdown, 等 guest 自收尾)

import ArgumentParser
import Foundation
import HVMControl
import HVMCore

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "软关机 (ACPI shutdown)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            try VMControl.stop(bundleURL: bundleURL)
            switch format {
            case .human: print("✔ 已发送软关机请求; guest 关机后 VMHost 自动退出")
            case .json:  printJSON(["ok": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
