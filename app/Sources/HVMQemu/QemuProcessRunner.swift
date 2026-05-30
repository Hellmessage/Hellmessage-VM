// HVMQemu/QemuProcessRunner.swift
// 轻量 Process 包装: 启动 qemu-system-aarch64, 捕获 stderr 落盘, 优雅 / 强制停止.
// Thin wrapper over SidecarProcessRunner (保留原 public API), 不带 sudo / socket wait.
// 不构造 argv (QemuArgsBuilder 的事), 不发 QMP (QmpClient 的事).

import Foundation

public final class QemuProcessRunner: @unchecked Sendable {

    public typealias State = SidecarProcessRunner.State
    public typealias LaunchError = SidecarProcessRunner.LaunchError

    public let binary: URL
    public let args: [String]
    public let stderrLog: URL?

    private let inner: SidecarProcessRunner

    public init(binary: URL, args: [String], stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.stderrLog = stderrLog
        self.inner = SidecarProcessRunner(config: .init(
            binary: binary, args: args, stderrLog: stderrLog,
            runAsRoot: false, socketPathForReadyWait: nil
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
