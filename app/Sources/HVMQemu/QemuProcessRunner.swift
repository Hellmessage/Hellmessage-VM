// HVMQemu/QemuProcessRunner.swift
// 轻量 Process 包装: 启动 qemu-system-aarch64, 捕获 stderr 落盘, 优雅 / 强制停止.
//
// 实现: 公共 lifecycle 已抽到 SidecarProcessRunner; 此类作为 thin wrapper 保留原 public
// API (避免破坏 QemuHostEntry / qemu-launch / 单测调用方). 不带 sudo, 不带 socket wait.
//
// 不做的事:
//   - 不构造 argv (那是 QemuArgsBuilder 的责任)
//   - 不发 QMP 命令做 ACPI shutdown (那是 QmpClient 的责任)
//   - 不绑定到 VMHandle (集成在 QemuHostEntry)

import Foundation

public final class QemuProcessRunner: @unchecked Sendable {

    public typealias State = SidecarProcessRunner.State
    public typealias LaunchError = SidecarProcessRunner.LaunchError

    public let binary: URL
    public let args: [String]
    public let stderrLog: URL?

    private let inner: SidecarProcessRunner

    /// extraFdConnections: 父进程会 connect 这些 unix socket 路径, 把连接 fd 透传给
    /// QEMU 子进程的 fd 3, 4, 5...; QEMU 命令行 `-netdev socket,fd=K` 用这些 fd 接 vmnet
    /// (与 lima/colima 一致). 空数组 = 全 NAT 或无 vmnet, 走默认 Foundation Process 路径.
    public init(binary: URL, args: [String], stderrLog: URL? = nil,
                extraFdConnections: [String] = []) {
        self.binary = binary
        self.args = args
        self.stderrLog = stderrLog
        self.inner = SidecarProcessRunner(config: .init(
            binary: binary, args: args, stderrLog: stderrLog,
            runAsRoot: false, socketPathForReadyWait: nil,
            extraFdConnections: extraFdConnections
        ))
    }

    public var state: State { inner.state }

    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        inner.addStateObserver(cb)
    }

    public func start() throws { try inner.start() }

    /// SIGTERM. QEMU 收 SIGTERM 不走 ACPI powerdown, 直接退; ACPI 走 QmpClient.systemPowerdown.
    public func terminate() { inner.terminate() }

    /// SIGKILL — 强杀, 对应 hvm-cli kill 语义
    public func forceKill() { inner.forceKill() }

    public func waitUntilExit() { inner.waitUntilExit() }
}
