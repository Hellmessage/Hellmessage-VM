// HVMQemu/SwtpmPaths.swift
// 定位 swtpm 二进制. 与 QemuPaths 同三段式回退:
//   1. 环境变量 HVM_SWTPM_PATH (开发期 / CI 显式覆盖)
//   2. QEMU 包内 Resources/QEMU/bin/swtpm (打包后 .app)
//   3. 系统位置 (/opt/homebrew/bin/swtpm Apple Silicon, /usr/local/bin/swtpm Intel)
//      最终用户机器若没装则报错; 详见 docs/QEMU_INTEGRATION.md
//
// 找到的二进制必须是可执行 Mach-O; 上层不再做 file 类型校验.

import Foundation

public enum SwtpmPaths {

    public static let envVar = "HVM_SWTPM_PATH"

    public enum NotFoundError: Error, Sendable, Equatable {
        case binaryMissing(searched: [String])
    }

    /// 解析 swtpm 二进制绝对路径. 失败抛 .binaryMissing.
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

        // 2. 包内 (打包后 .app, 与 qemu-system-aarch64 同 bin/ 目录)
        if let qemuRoot = try? QemuPaths.resolveRoot() {
            let bundled = qemuRoot.appendingPathComponent("bin/swtpm")
            searched.append("bundled \(bundled.path)")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        // 3. 系统位置 (Homebrew default; 最终用户若没 brew install swtpm 则失败)
        for sys in ["/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"] {
            searched.append(sys)
            if FileManager.default.isExecutableFile(atPath: sys) {
                return URL(fileURLWithPath: sys)
            }
        }

        throw NotFoundError.binaryMissing(searched: searched)
    }
}
