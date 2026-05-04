// DecryptCommand.swift
// hvm-cli decrypt <vm> — 加密 QEMU VM 转回明文 (冷迁移 in-place).
//
// 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu

struct DecryptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decrypt",
        abstract: "加密 VM → 明文 VM (仅 QEMU engine, 冷迁移). disks 仍是 qcow2"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "跳过最终二次确认")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)

            if BundleLock.isBusy(bundleURL: bundleURL) {
                let h = BundleLock.inspect(bundleURL: bundleURL)
                throw HVMError.bundle(.busy(pid: h?.pid ?? 0, holderMode: h?.mode ?? "unknown"))
            }
            guard let scheme = EncryptedBundleIO.detectScheme(at: bundleURL),
                  scheme == .qemuPerfile else {
                throw HVMError.encryption(.parseFailed(reason: "VM 不是 QEMU 加密形态"))
            }
            let routing = try RoutingJSON.read(from: RoutingJSON.locationForQemuBundle(bundleURL))

            if format == .human {
                print("⚠ 即将把 \(routing.displayName) 转为明文 VM:")
                print("  - disks / nvram / config 全部变明文")
                print("  - 数据可被任何能读 bundle 文件的进程查看 (host 用户隔离仍生效)")
                print("  - 需要 ≈ 主盘 + 数据盘大小总和的临时空间")
                print("")
                if !force {
                    print("继续? [y/N] ", terminator: "")
                    let line = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                    if !["y", "yes"].contains(line) { print("已取消"); return }
                }
            }

            let password = try PasswordPrompt.read(prompt: "密码 (\(routing.displayName)): ")
            let qemuImg = try QemuPaths.qemuImgBinary()
            let progressLog: (String) -> Void = { msg in
                if self.format == .human { print("  \(msg)") }
            }
            let result = try DecryptVMOperation.decrypt(
                bundleURL: bundleURL, password: password, qemuImg: qemuImg,
                progressLog: progressLog
            )

            switch format {
            case .human:
                print("")
                print("✔ \(routing.displayName) 已转明文")
                print("  bundle: \(result.bundleURL.path)")
                print("  下一步: hvm-cli start \(vm)  (无密码, 直接启动)")
            case .json:
                printJSON(["ok": "true", "bundlePath": result.bundleURL.path])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
