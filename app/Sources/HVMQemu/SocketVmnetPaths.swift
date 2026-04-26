// HVMQemu/SocketVmnetPaths.swift
// 定位 socket_vmnet 二进制 (Lima 项目: macOS vmnet 的非 root 桥接 daemon).
// 与 SwtpmPaths 同三段式回退:
//   1. 环境变量 HVM_SOCKET_VMNET_PATH
//   2. QEMU 包内 Resources/QEMU/bin/socket_vmnet (打包后 .app)
//   3. 系统位置 (/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet, /opt/homebrew/bin/, /usr/local/...)
//
// 与 swtpm 关键差异: socket_vmnet 必须由 root 启动 (vmnet API 限制).
// 调用方 (SocketVmnetRunner) 通过 sudo + NOPASSWD sudoers 拉起, 详见
// scripts/install-vmnet-helper.sh 与 docs/QEMU_INTEGRATION.md「网络方案」.

import Foundation

public enum SocketVmnetPaths {

    public static let envVar = "HVM_SOCKET_VMNET_PATH"

    public enum NotFoundError: Error, Sendable, Equatable {
        case binaryMissing(searched: [String])
    }

    /// 解析 socket_vmnet 二进制绝对路径. 失败抛 .binaryMissing.
    public static func locate() throws -> URL {
        var searched: [String] = []

        // 1. 环境变量
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            searched.append("env $\(envVar)=\(env)")
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        // 2. 包内 (打包后 .app, 与 swtpm/qemu-system-aarch64 同 bin/ 目录)
        if let qemuRoot = try? QemuPaths.resolveRoot() {
            let bundled = qemuRoot.appendingPathComponent("bin/socket_vmnet")
            searched.append("bundled \(bundled.path)")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        // 3. 系统位置
        // brew 装会落在 /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet (keg-only formula),
        // 同时 /opt/homebrew/bin 有 symlink. Intel mac 走 /usr/local 兜底.
        let candidates = [
            "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet",
            "/opt/homebrew/bin/socket_vmnet",
            "/usr/local/opt/socket_vmnet/bin/socket_vmnet",
            "/usr/local/bin/socket_vmnet",
        ]
        for sys in candidates {
            searched.append(sys)
            if FileManager.default.isExecutableFile(atPath: sys) {
                return URL(fileURLWithPath: sys)
            }
        }

        throw NotFoundError.binaryMissing(searched: searched)
    }
}
