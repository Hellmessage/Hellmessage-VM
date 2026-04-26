// HVMQemu/QemuPaths.swift
// 解析 QEMU 二进制 + 固件 + share 目录的实际路径.
//
// 三段式回退 (优先级递减):
//   1. 环境变量 HVM_QEMU_ROOT - CI / 开发期显式覆盖
//   2. Bundle.main/Contents/Resources/QEMU - 打包后的 .app 走这里
//   3. 从 executable 与 cwd 向上找 third_party/qemu/ - swift run / swift test
//
// 决策记录见 docs/QEMU_INTEGRATION.md "关键决策" + CLAUDE.md "QEMU 后端约束".

import Foundation

public enum QemuPaths {

    /// 环境变量名: 显式指定 QEMU 根目录, 对所有自动探测优先生效
    public static let rootEnvVar = "HVM_QEMU_ROOT"

    public enum NotFoundError: Error, Sendable, Equatable {
        /// 所有候选路径都没找到可执行的 qemu-system-aarch64
        case rootMissing(searched: [String])
        /// QEMU 根目录在但缺关键文件 (firmware / share)
        case fileMissing(path: String)
    }

    /// 解析 QEMU 根目录. 失败抛 .rootMissing.
    public static func resolveRoot() throws -> URL {
        var searched: [String] = []

        // 1. 环境变量
        if let env = ProcessInfo.processInfo.environment[rootEnvVar], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            searched.append("env $\(rootEnvVar)=\(env)")
            if isValidRoot(url) { return url }
        }

        // 2. Bundle.main 资源 (打包后 .app)
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent("QEMU", isDirectory: true)
            searched.append("Bundle.main/QEMU at \(candidate.path)")
            if isValidRoot(candidate) { return candidate }
        }

        // 3a. 从 main bundle URL 向上找 third_party/qemu/ (开发期, .build/... 路径)
        var dir = Bundle.main.bundleURL
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("third_party/qemu", isDirectory: true)
            if isValidRoot(candidate) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        searched.append("Bundle.main parents → third_party/qemu")

        // 3b. 从 cwd 向上找 (兜底, 比如直接 swift test 时 cwd = 项目根)
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<10 {
            let candidate = cwd.appendingPathComponent("third_party/qemu", isDirectory: true)
            if isValidRoot(candidate) {
                return candidate
            }
            let parent = cwd.deletingLastPathComponent()
            if parent == cwd { break }
            cwd = parent
        }
        searched.append("cwd parents → third_party/qemu")

        throw NotFoundError.rootMissing(searched: searched)
    }

    /// qemu-system-aarch64 绝对路径
    public static func qemuBinary() throws -> URL {
        let bin = try resolveRoot().appendingPathComponent("bin/qemu-system-aarch64")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw NotFoundError.fileMissing(path: bin.path)
        }
        return bin
    }

    /// EDK2 aarch64 UEFI firmware (Linux + Windows arm64 启动必需)
    public static func edk2Firmware() throws -> URL {
        let fw = try resolveRoot().appendingPathComponent("share/qemu/edk2-aarch64-code.fd")
        guard FileManager.default.isReadableFile(atPath: fw.path) else {
            throw NotFoundError.fileMissing(path: fw.path)
        }
        return fw
    }

    /// QEMU share 目录 (含 keymaps / firmware descriptors / 等). 用于 -L 选项
    public static func shareDir() throws -> URL {
        try resolveRoot().appendingPathComponent("share/qemu")
    }

    // MARK: - 内部

    /// 判断给定 URL 是否是有效 QEMU 根 (含可执行的 qemu-system-aarch64)
    private static func isValidRoot(_ url: URL) -> Bool {
        let bin = url.appendingPathComponent("bin/qemu-system-aarch64")
        return FileManager.default.isExecutableFile(atPath: bin.path)
    }
}
