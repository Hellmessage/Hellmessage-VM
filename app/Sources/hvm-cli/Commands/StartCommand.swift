// StartCommand.swift
// hvm-cli start — 后台拉起 VMHost (HVM.app --host-mode-bundle), 立即返回.
// 加密 VM (config.encryption.enabled = true) 启动期 prompt password 走 stdin Pipe 透传.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动 VM (后台, 立即返回). 加密 VM 会 prompt 密码"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Option(name: .long, help: "密码 (从 stdin 一行读, 仅供脚本; 不设则 tty prompt)")
    var passwordStdin: Bool = false

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

            // 加密形态检测 (不解密) — 加密 VM 走 prompt password, 走 EncryptedBundleIO.unlock
            // 拿 displayName + id 用于日志路径; 明文 VM 走 BundleIO.load (现状).
            let displayName: String
            let vmId: UUID
            var password: String? = nil
            if let scheme = EncryptedBundleIO.detectScheme(at: bundleURL) {
                let routingURL: URL = {
                    switch scheme {
                    case .vzSparsebundle: return RoutingJSON.locationForSparsebundle(bundleURL)
                    case .qemuPerfile:    return RoutingJSON.locationForQemuBundle(bundleURL)
                    }
                }()
                let routing = try RoutingJSON.read(from: routingURL)
                if scheme == .vzSparsebundle {
                    throw HVMError.encryption(.parseFailed(
                        reason: "VZ 加密 VM 启动暂未实现 (docs/v3/ENCRYPTION.md v2.4 QEMU 优先); 等 VZ 接入 PR"
                    ))
                }
                displayName = routing.displayName
                vmId = routing.vmId
                // Prompt 密码
                if passwordStdin {
                    // 脚本模式: 读 stdin 一行
                    let line = readLine(strippingNewline: true) ?? ""
                    if line.isEmpty {
                        throw HVMError.config(.missingField(name: "password (stdin 为空)"))
                    }
                    password = line
                } else {
                    password = try PasswordPrompt.read(prompt: "密码 (\(displayName)): ")
                }
            } else {
                // 明文 VM
                let config = try BundleIO.load(from: bundleURL)
                displayName = config.displayName
                vmId = config.id
            }

            let pid = try HostLauncher.launch(bundleURL: bundleURL, password: password)
            let logDir = HVMPaths.vmLogsDir(displayName: displayName, id: vmId).path

            switch format {
            case .human:
                print("✔ 已启动 VMHost (pid=\(pid))")
                if password != nil {
                    print("  (加密 VM, password 已通过 stdin Pipe 透传)")
                }
                print("  日志: \(logDir)")
                print("  查看状态: hvm-cli status \(vm)")
            case .json:
                printJSON([
                    "ok": "true",
                    "hostPid": "\(pid)",
                    "bundlePath": bundleURL.path,
                    "encrypted": password != nil ? "true" : "false",
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
