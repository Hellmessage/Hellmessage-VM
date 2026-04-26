// DeleteCommand.swift
// hvm-cli delete — 删除 VM bundle (默认移废纸篓, --purge 彻底 rm)

import ArgumentParser
import AppKit
import Foundation
import HVMBundle
import HVMCore

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "删除 VM bundle"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "彻底删除, 不经废纸篓")
    var purge: Bool = false

    @Flag(name: .long, help: "跳过确认")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)

            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }

            if purge && !force && format == .human {
                print("--purge 将永久删除 \(bundleURL.path). 继续? [y/N] ", terminator: "")
                let line = readLine() ?? ""
                if !["y", "Y", "yes", "YES"].contains(line.trimmingCharacters(in: .whitespaces)) {
                    print("已取消")
                    return
                }
            }

            if purge {
                try FileManager.default.removeItem(at: bundleURL)
                switch format {
                case .human: print("✔ 已永久删除 \(bundleURL.path)")
                case .json:  printJSON(["ok": "true", "deleted": bundleURL.path])
                }
            } else {
                // 移废纸篓
                var resultURL: NSURL?
                try FileManager.default.trashItem(at: bundleURL, resultingItemURL: &resultURL)
                switch format {
                case .human: print("✔ 已移入废纸篓")
                case .json:  printJSON(["ok": "true", "trashed": bundleURL.path])
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
