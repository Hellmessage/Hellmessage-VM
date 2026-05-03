// EncryptCommand.swift
// hvm-cli encrypt <vm> — 把现有明文 QEMU VM 转成加密 VM (冷迁移 in-place).
//
// 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10a.
//
// 限制 (实现层面):
//   - 仅 QEMU engine. VZ engine VM 拒绝 (raw → LUKS qcow2 切引擎需独立 PR)
//   - VM 必须 stopped (.edit lock 抢)
//   - Win VM TPM state 重置 (现有 swtpm state 是明文, 用新 swtpm-key 启动 swtpm 解不开)
//   - 不可中断 (转换中失败 → 临时文件清, 主 bundle 不动; 替换阶段失败 → 部分破坏)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu

struct EncryptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encrypt",
        abstract: "把现有明文 VM 转成加密 VM (仅 QEMU engine, 冷迁移). Win VM 会重置 TPM"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "跳过最终二次确认 (默认会要求 y/N)")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)

            // 校验已停
            if BundleLock.isBusy(bundleURL: bundleURL) {
                let holder = BundleLock.inspect(bundleURL: bundleURL)
                throw HVMError.bundle(.busy(
                    pid: holder?.pid ?? 0,
                    holderMode: holder?.mode ?? "unknown"
                ))
            }
            // 已加密 VM 拒
            if EncryptedBundleIO.detectScheme(at: bundleURL) != nil {
                throw HVMError.encryption(.parseFailed(reason: "VM 已是加密形态"))
            }

            // 读 config 看 engine + guestOS (报错前置)
            let config = try BundleIO.load(from: bundleURL)
            guard config.engine == .qemu else {
                throw HVMError.config(.invalidEnum(
                    field: "engine", raw: config.engine.rawValue,
                    allowed: ["qemu (VZ engine VM 加密暂不支持)"]
                ))
            }
            guard config.guestOS != .macOS else {
                throw HVMError.config(.invalidEnum(
                    field: "guestOS", raw: "macOS",
                    allowed: ["linux / windows"]
                ))
            }

            // 用户警告 + 确认
            if format == .human {
                print("⚠ 即将把 \(config.displayName) 转为加密 VM:")
                print("  - 引擎: \(config.engine.rawValue) (不变)")
                print("  - 主盘 / 数据盘: 转 LUKS qcow2 (AES-256-XTS)")
                if config.guestOS == .windows {
                    print("  - OVMF VARS: 转 LUKS qcow2 (BootOrder 保留)")
                    print("  - ⚠ TPM 状态将重置: BitLocker / SecureBoot 信任根丢失, 首启 Win 会重新 attest")
                }
                print("  - config.yaml: AES-GCM in-place 加密")
                print("  - 临时空间需求: ≈ 主盘 + 数据盘大小总和 (转换期间)")
                print("  - 跨机器: 拷整 .hvmz 到另一台 Mac, 用同密码可启动")
                print("")
                if !force {
                    print("继续? [y/N] ", terminator: "")
                    let line = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                    if !["y", "yes"].contains(line) {
                        print("已取消")
                        return
                    }
                }
            }

            // Prompt password (双重)
            let password = try PasswordPrompt.read(
                prompt: "为加密 VM \(config.displayName) 设置密码: ",
                confirm: true,
                minLength: 4
            )

            // OVMF VARS template (Win 才需要)
            let qemuImg = try QemuPaths.qemuImgBinary()
            var template: URL? = nil
            if config.guestOS == .windows {
                let qemuRoot = try QemuPaths.resolveRoot()
                template = qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-vars.fd")
            }

            // 执行
            let progressLog: (String) -> Void = { msg in
                if self.format == .human {
                    print("  \(msg)")
                }
            }
            let result = try EncryptVMOperation.encrypt(
                bundleURL: bundleURL,
                password: password,
                qemuImg: qemuImg,
                ovmfVarsTemplate: template,
                progressLog: progressLog
            )

            switch format {
            case .human:
                print("")
                print("✔ \(config.displayName) 已加密")
                print("  bundle: \(result.bundleURL.path)")
                if result.tpmReset {
                    print("  ⚠ TPM 已重置")
                }
                print("  下一步: hvm-cli start \(vm)  (会 prompt 密码)")
            case .json:
                printJSON([
                    "ok": "true",
                    "bundlePath": result.bundleURL.path,
                    "tpmReset": result.tpmReset ? "true" : "false",
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
