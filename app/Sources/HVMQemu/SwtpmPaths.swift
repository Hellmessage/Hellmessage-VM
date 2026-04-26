// HVMQemu/SwtpmPaths.swift
// 定位 swtpm 二进制. 严格只走包内 (/Applications/HVM.app 或开发期 build/HVM.app),
// 不再 fallback 到系统 brew (/opt/homebrew, /usr/local) — 防止本机 brew 版本与
// 包内版本不一致引入诡异 bug (例: brew 升级 swtpm 后 NV header 不兼容).
//
// 路径优先级:
//   1. 环境变量 HVM_SWTPM_PATH (CI / 开发期显式覆盖)
//   2. QemuPaths.resolveRoot()/bin/swtpm — 涵盖:
//      a) Bundle.main/Resources/QEMU (打包后 /Applications/HVM.app 或 build/HVM.app)
//      b) 从 Bundle.main / cwd 向上找 third_party/qemu (swift run / swift test 兜底)
//
// 缺则抛 .binaryMissing, 调用方负责引导 "make qemu / make build-all".

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

        // 2. 包内 (打包后 .app, 与 qemu-system-aarch64 同 bin/ 目录).
        // QemuPaths.resolveRoot() 已涵盖 Bundle.main/Resources/QEMU + dev third_party/qemu 兜底,
        // 所以这里不再 brew fallback — 只信任包内副本, 防版本错位.
        if let qemuRoot = try? QemuPaths.resolveRoot() {
            let bundled = qemuRoot.appendingPathComponent("bin/swtpm")
            searched.append("bundled \(bundled.path)")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        throw NotFoundError.binaryMissing(searched: searched)
    }
}
