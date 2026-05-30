// DeleteCommand.swift
// hvm-cli delete — 删除 VM bundle (默认移废纸篓, --purge 彻底 rm).
//
// 加密 VM + --purge: 默认走 SecureErase 单 pass random 覆写所有 ciphertext 文件,
// 防 APFS free block 取证恢复. 跟"加密 VM 删了应该不可恢复"语义对齐.
// (TODO #11)

import ArgumentParser
import Foundation
import HVMBundle
import HVMControl
import HVMCore
import HVMEncryption

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "删除 VM bundle"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "彻底删除, 不经废纸篓")
    var purge: Bool = false

    @Flag(name: .long, help: "强制 secure-erase 整 bundle (单 pass random 覆写, 防 APFS free block 取证). 加密 VM 默认开, 明文 VM 默认关")
    var secureErase: Bool = false

    @Flag(name: .long, help: "跳过确认")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)

            // 加密 VM + --purge: 默认走 secure-erase. 用户显式 --secure-erase 也强制走 (即便明文 VM)
            let isEncrypted = EncryptedBundleIO.detectScheme(at: bundleURL) != nil
            let useSecureErase = purge && (isEncrypted || secureErase)

            if purge && !force && format == .human {
                let suffix = useSecureErase ? " (会 secure-erase 单 pass random 覆写, 较慢)" : ""
                print("--purge 将永久删除 \(bundleURL.path)\(suffix). 继续? [y/N] ", terminator: "")
                let line = readLine() ?? ""
                if !["y", "Y", "yes", "YES"].contains(line.trimmingCharacters(in: .whitespaces)) {
                    print("已取消")
                    return
                }
            }

            // 模式分流走 VMControl.delete (含 running 互斥检查). trash / purge / secureErase
            let mode: VMControl.DeleteMode = !purge ? .trash : (useSecureErase ? .secureErase : .purge)
            if useSecureErase, format == .human { print("正在 secure-erase ...") }
            try VMControl.delete(bundleURL: bundleURL, mode: mode)

            switch format {
            case .human:
                switch mode {
                case .trash:       print("✔ 已移入废纸篓")
                case .purge:       print("✔ 已永久删除 \(bundleURL.path)")
                case .secureErase: print("✔ 已永久删除 + secure-erase \(bundleURL.path)")
                }
            case .json:
                switch mode {
                case .trash: printJSON(["ok": "true", "trashed": bundleURL.path])
                default:     printJSON(["ok": "true", "deleted": bundleURL.path,
                                        "secureErase": useSecureErase ? "true" : "false"])
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
