// HVMQemu/SwtpmRunner.swift
// swtpm 子进程包装. Thin wrapper over SidecarProcessRunner, 加 ctrlSocketPath 字段
// 与 waitForSocketReady 转发 (swtpm 启动后 host 等其 unix socket 可用才让 QEMU 连).
//
// 与 QemuProcessRunner 差异:
//   - 暴露 ctrlSocketPath (调用方需读)
//   - waitForSocketReady 可用 (Qemu Runner 没暴露这个)

import Foundation

public final class SwtpmRunner: @unchecked Sendable {

    public typealias State = SidecarProcessRunner.State
    public typealias LaunchError = SidecarProcessRunner.LaunchError

    public let binary: URL
    public let args: [String]
    /// ctrl socket 路径 (与 args 中的 --ctrl 同步; runner 知道路径以便 waitForSocketReady)
    public let ctrlSocketPath: String
    public let stderrLog: URL?

    private let inner: SidecarProcessRunner

    public init(binary: URL, args: [String], ctrlSocketPath: String, stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.ctrlSocketPath = ctrlSocketPath
        self.stderrLog = stderrLog
        self.inner = SidecarProcessRunner(config: .init(
            binary: binary, args: args, stderrLog: stderrLog,
            runAsRoot: false, socketPathForReadyWait: ctrlSocketPath
        ))
    }

    public var state: State { inner.state }

    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        inner.addStateObserver(cb)
    }

    public func start() throws { try inner.start() }

    /// poll 等 ctrl socket 文件出现 (swtpm bind 后才能让 QEMU 连);
    /// swtpm 早退立即 false.
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        await inner.waitForSocketReady(timeoutSec: timeoutSec)
    }

    /// SIGTERM, swtpm 收到后清理并退出
    public func terminate() { inner.terminate() }

    /// SIGKILL, 强杀
    public func forceKill() { inner.forceKill() }

    public func waitUntilExit() { inner.waitUntilExit() }
}
