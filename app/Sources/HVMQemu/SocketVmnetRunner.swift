// HVMQemu/SocketVmnetRunner.swift
// socket_vmnet 子进程包装. Thin wrapper over SidecarProcessRunner, runAsRoot=true 让
// SidecarProcessRunner 通过 sudo -n 拉起 + forceKill 用 sudo+pkill 杀 root 子进程.
//
// 调用方负责:
//   1. 通过 install-vmnet-helper.sh 配置 NOPASSWD sudoers (否则 sudo -n 立即失败)
//   2. SocketVmnetPaths.locate() 拿 socket_vmnet 二进制
//   3. SocketVmnetArgsBuilder.build() 拿 argv
//   4. SocketVmnetRunner(binary:args:socketPath:).start()

import Foundation

public final class SocketVmnetRunner: @unchecked Sendable {

    public typealias State = SidecarProcessRunner.State
    public typealias LaunchError = SidecarProcessRunner.LaunchError

    /// socket_vmnet 二进制 (由 SocketVmnetPaths.locate() 解析). 内部走 sudo 拉起.
    public let binary: URL
    /// SocketVmnetArgsBuilder.build() 的输出
    public let args: [String]
    /// socket_vmnet 监听的 unix socket 路径 (跟 args 中的最后一个参数同步; 用于 waitForSocketReady)
    public let socketPath: String
    public let stderrLog: URL?

    private let inner: SidecarProcessRunner

    public init(binary: URL, args: [String], socketPath: String, stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.socketPath = socketPath
        self.stderrLog = stderrLog
        self.inner = SidecarProcessRunner(config: .init(
            binary: binary, args: args, stderrLog: stderrLog,
            runAsRoot: true,                        // sudo -n 包装
            socketPathForReadyWait: socketPath      // 等 socket 出现
        ))
    }

    public var state: State { inner.state }

    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        inner.addStateObserver(cb)
    }

    /// sudoers NOPASSWD 未配则 sudo -n 立即非 0 退, runner.state = .exited(1).
    public func start() throws { try inner.start() }

    /// poll 等 socket 文件出现; 进程早退立即 false.
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        await inner.waitForSocketReady(timeoutSec: timeoutSec)
    }

    /// SIGTERM 给 sudo, sudo 通常会 forward 给 socket_vmnet 让其干净退.
    public func terminate() { inner.terminate() }

    /// SIGKILL — sudo + pkill -P 兜底杀 root 子进程, 再 kill sudo 自己 (见 SidecarProcessRunner.forceKill).
    public func forceKill() { inner.forceKill() }

    public func waitUntilExit() { inner.waitUntilExit() }
}
