// RekeyCommand.swift
// hvm-cli rekey <vm> — 加密 QEMU VM 改密.
//
// 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b.
// rekey 重置 TPM (swtpm 现有 state 用 old swtpm-key 加密, 用 new 启动 swtpm 解不开).

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu

struct RekeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rekey",
        abstract: "改密加密 VM (LUKS keyslot 重写, 几毫秒级; Win 重置 TPM)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

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
                throw HVMError.encryption(.parseFailed(reason: "VM 不是加密形态"))
            }
            let routing = try RoutingJSON.read(from: RoutingJSON.locationForQemuBundle(bundleURL))

            if format == .human {
                print("⚠ 改密 \(routing.displayName):")
                print("  - 所有 LUKS qcow2 (disks + OVMF VARS) keyslot 重写 (毫秒级, 不重密 DEK)")
                print("  - config.yaml.enc 用 new key 重 AES-GCM seal")
                print("  - routing JSON 写新 salt (跨机器需用新密码)")
                if (try? routingHasWindowsTpm(bundle: bundleURL)) ?? false {
                    print("  - ⚠ TPM 状态会重置 (swtpm 0.10 无 rewrap 工具)")
                    print("    → 后果: BitLocker recovery key / TPM-sealed secrets 全丢")
                    print("    → 改密前请确认你已 backup guest 内 BitLocker recovery key")
                    print("      (Win 设置 → 系统 → 恢复 → 备份恢复密钥; Microsoft 账户 / 打印 / U盘)")
                }
                print("")
            }

            let oldPw = try PasswordPrompt.read(prompt: "原密码: ")
            let newPw = try PasswordPrompt.read(prompt: "新密码: ", confirm: true, minLength: 4)

            if oldPw == newPw {
                throw HVMError.config(.invalidEnum(
                    field: "password", raw: "新密码与原密码相同",
                    allowed: ["新密码必须 ≠ 原密码"]
                ))
            }

            let qemuImg = try QemuPaths.qemuImgBinary()
            let progressLog: (String) -> Void = { msg in
                if self.format == .human { print("  \(msg)") }
            }
            let result = try RekeyVMOperation.rekey(
                bundleURL: bundleURL, oldPassword: oldPw, newPassword: newPw,
                qemuImg: qemuImg, progressLog: progressLog
            )

            switch format {
            case .human:
                print("")
                print("✔ \(routing.displayName) 已改密")
                if result.tpmReset { print("  ⚠ TPM 已重置") }
                print("  下次 hvm-cli start 用新密码")
            case .json:
                printJSON(["ok": "true", "tpmReset": result.tpmReset ? "true" : "false"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    /// 简单判 bundle 是否 Win + 有 tpm 目录. 不解密 — 仅看磁盘是否存在 tpm/ 子目录.
    private func routingHasWindowsTpm(bundle: URL) throws -> Bool {
        let tpmDir = BundleLayout.tpmStateDir(bundle)
        return FileManager.default.fileExists(atPath: tpmDir.path)
    }
}
