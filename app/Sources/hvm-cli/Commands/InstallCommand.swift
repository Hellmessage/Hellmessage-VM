// InstallCommand.swift
// hvm-cli install — 跑 macOS guest 全自动装机 (VZMacOSInstaller).
//
// Linux 装机不走这条路: 直接 `hvm-cli start <name>` 挂 ISO 进 guest 自己装,
// 完成后 `hvm-cli boot-from-disk <name>` 切到只硬盘启动.
// 详见 docs/GUEST_OS_INSTALL.md

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMInstall

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "macOS guest 全自动装机 (Linux 走 start + 手动安装)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "覆盖 config.macOS.ipsw 用的 IPSW 路径")
    var ipsw: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Flag(name: .long, help: "json 模式下流式输出每一帧 progress, 否则只在阶段切换时输出")
    var follow: Bool = false

    @MainActor
    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let config = try BundleIO.load(from: bundleURL)

            switch config.guestOS {
            case .linux:
                throw HVMError.install(.installerFailed(
                    reason: "Linux guest 不支持 install 子命令; 走 hvm-cli start <name> 进 guest 内手动装, 然后 hvm-cli boot-from-disk <name>"
                ))
            case .windows:
                throw HVMError.install(.installerFailed(
                    reason: "Windows guest 不走 install 子命令; 走 hvm-cli start <name> 进 guest 内手动装, 然后 hvm-cli boot-from-disk <name>"
                ))
            case .macOS:
                break
            }

            // 已装过的拒绝重装 (覆盖 auxiliary 会丢 hardware-model 绑定)
            if config.macOS?.autoInstalled == true {
                throw HVMError.install(.installerFailed(
                    reason: "已装好的 macOS bundle 不能重装. 删 bundle 重建或改 config.json 后重试"
                ))
            }

            // IPSW 路径: --ipsw 覆盖 > config.macOS.ipsw
            guard let ipswPath = self.ipsw ?? config.macOS?.ipsw else {
                throw HVMError.config(.missingField(name: "macOS.ipsw"))
            }
            let ipswURL = URL(fileURLWithPath: ipswPath)

            let installer = MacInstaller()
            var lastFraction: Double = -1

            try await installer.install(
                bundleURL: bundleURL,
                config: config,
                ipswURL: ipswURL,
                onProgress: { progress in
                    Self.report(progress, format: format, follow: follow, lastFraction: &lastFraction)
                }
            )

            switch format {
            case .human:
                // 收尾换行(覆盖最后一帧 \r 行)
                print("")
                print("✔ 已装机完成: \(bundleURL.path)")
                print("下一步: hvm-cli start \(vm)")
            case .json:
                printJSON(["phase": "succeeded", "bundlePath": bundleURL.path])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    /// 把 InstallProgress 翻成对外输出. human 用 \r 原地刷新百分比, json 一行一帧.
    private static func report(
        _ progress: InstallProgress,
        format: OutputFormat,
        follow: Bool,
        lastFraction: inout Double
    ) {
        switch progress {
        case .preparing:
            switch format {
            case .human: print("[preparing] 校验 IPSW + 生成 auxiliary…")
            case .json:  printJSON(["phase": "preparing"])
            }

        case .installing(let f):
            switch format {
            case .human:
                // \r 覆盖, 不加换行. 限流到 0.5% 减少终端抖动.
                if f - lastFraction >= 0.005 || f >= 1.0 {
                    let pct = String(format: "%.1f", f * 100)
                    print("\rInstalling macOS: \(pct)%", terminator: "")
                    fflush(stdout)
                    lastFraction = f
                }
            case .json:
                // --follow 流式; 否则只在 1% 步进点输出, 避免 stdout 灌爆
                if follow || f - lastFraction >= 0.01 {
                    printJSON(["phase": "installing", "fraction": String(format: "%.4f", f)])
                    lastFraction = f
                }
            }

        case .finalizing:
            switch format {
            case .human:
                print("\n[finalizing] 写 config.macOS.autoInstalled=true + bootFromDiskOnly=true…")
            case .json:
                printJSON(["phase": "finalizing"])
            }
        }
    }
}
