// HVMQemu/QemuPaths.swift
// 解析 QEMU 二进制 + 固件 + share 目录的实际路径.
//
// 严格只走 .app 包内, 不再 fallback 到 third_party/qemu-stage / brew (CLAUDE.md 第三方二进制约束):
//   1. 环境变量 HVM_QEMU_ROOT - CI / 调试显式覆盖
//   2. Bundle.main/Contents/Resources/QEMU - 当前进程 .app 包内
//      a) dev: open build/HVM.app → Bundle.main = build/HVM.app
//      b) prod: open /Applications/HVM.app → Bundle.main = /Applications/HVM.app
//
// 不再支持 swift run / swift test 直接跑 QEMU 路径 (测试用 env override 覆盖).
// 决策记录见 docs/QEMU_INTEGRATION.md + CLAUDE.md "第三方二进制 / Helper 脚本约束".

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

        // 2. Bundle.main 资源 (打包后 .app: dev = build/HVM.app, prod = /Applications/HVM.app)
        // 不再 fallback 到 third_party/qemu-stage — 见 CLAUDE.md "第三方二进制 / Helper 脚本约束".
        // swift run / swift test 须用 HVM_QEMU_ROOT env 显式指定 root.
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent("QEMU", isDirectory: true)
            searched.append("Bundle.main/QEMU at \(candidate.path)")
            if isValidRoot(candidate) { return candidate }
        }

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

    /// qemu-img 绝对路径. QEMU 后端创建 / 扩容 qcow2 必经.
    /// 已经随 QEMU 一起打包进 .app/Contents/Resources/QEMU/bin/.
    public static func qemuImgBinary() throws -> URL {
        let bin = try resolveRoot().appendingPathComponent("bin/qemu-img")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw NotFoundError.fileMissing(path: bin.path)
        }
        return bin
    }

    // 注: 不提供 socket_vmnet locator — 该二进制**不入 .app**, 由用户 brew install,
    // 系统级 launchd daemon (label `com.hellmessage.hvm.vmnet.*`) 拉起, 监听固定路径
    // `/var/run/socket_vmnet[.host|.bridged.<iface>]`. QEMU argv 直接
    // `-netdev stream,addr.type=unix,addr.path=...` 连 daemon — daemon 协议 (4-byte
    // length-prefix framing) 跟 QEMU `-netdev stream` 兼容, 不需要 socket_vmnet_client
    // wrapper, 不需要父进程透传 fd (老 sidecar fd-passing 路径已下线).
    // 详见 CLAUDE.md "socket_vmnet 网络约束" 与 docs/v1/NETWORK.md.

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
