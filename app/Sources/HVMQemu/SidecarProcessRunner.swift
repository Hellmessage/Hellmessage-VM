// HVMQemu/SidecarProcessRunner.swift
// 公共 sidecar 子进程编排. QemuProcessRunner / SwtpmRunner 都是
// 它的 thin wrapper (保留各自 public API, 内部转发到这里).
//
// 抽出原因: 多个 Runner 状态机 / lifecycle / stderr 落盘 / observer 几乎逐字相同 (>75%
// 复制); bug 修一处忘另一处的风险高. 抽到一个 class 后, 通过 Config 控制差异化行为
// (是否走 sudo, 是否带 socket-ready poll), 不同业务都跑同一份代码.
// 注: socket_vmnet 改为系统级 launchd daemon 后已不再有 SocketVmnetRunner.
//
// 状态机: .idle → .running(pid) → .exited(code) | .crashed(signal)

import Foundation
import Darwin
import HVMCore

public final class SidecarProcessRunner: @unchecked Sendable {

    public enum State: Sendable, Equatable {
        case idle
        case running(pid: Int32)
        case exited(code: Int32)
        case crashed(signal: Int32)
    }

    public enum LaunchError: Error, Sendable {
        case alreadyStarted
        case spawnFailed(reason: String)
    }

    public struct Config: Sendable {
        /// 真正要跑的 binary 绝对路径. runAsRoot=true 时 sudo 之后 exec 它.
        public let binary: URL
        public let args: [String]
        /// stderr tee 到此文件 (append). nil 丢弃; 主要用于诊断 sidecar 启动失败
        public let stderrLog: URL?
        /// true → 用 /usr/bin/sudo -n <binary> <args> 拉起;
        ///        forceKill 改用 sudo + pkill -P 杀 root 子进程 (SIGKILL 不能被 sudo forward)
        /// false → 直接 exec binary, kill 直接给 pid
        public let runAsRoot: Bool
        /// 非 nil → waitForSocketReady 会 poll 此路径出现 + 进程未早退;
        /// nil → waitForSocketReady 立即返 false (业务方未提供, 不应调)
        public let socketPathForReadyWait: String?

        public init(
            binary: URL,
            args: [String],
            stderrLog: URL? = nil,
            runAsRoot: Bool = false,
            socketPathForReadyWait: String? = nil
        ) {
            self.binary = binary
            self.args = args
            self.stderrLog = stderrLog
            self.runAsRoot = runAsRoot
            self.socketPathForReadyWait = socketPathForReadyWait
        }
    }

    public let config: Config

    private let lock = NSLock()
    private var _state: State = .idle
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrFileHandle: FileHandle?
    private var observers: [(State) -> Void] = []

    public init(config: Config) {
        self.config = config
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// 状态变化回调 (从 process 终止线程触发, 调用方需自行 dispatch 到主线程)
    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(cb)
    }

    /// 启动子进程. runAsRoot=true 时走 sudo -n 包装.
    public func start() throws {
        lock.lock()
        guard case .idle = _state else {
            lock.unlock()
            throw LaunchError.alreadyStarted
        }
        lock.unlock()

        // stderr 落盘准备 (append, 跨 start 累积)
        if let logURL = config.stderrLog {
            let fm = FileManager.default
            try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            stderrFileHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? stderrFileHandle?.seekToEnd()
        }

        // sudo 包装 vs 直接 exec
        if config.runAsRoot {
            // -n: 不允许 prompt; sudoers NOPASSWD 没配立即非 0 退 (避免 hang)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", config.binary.path] + config.args
        } else {
            process.executableURL = config.binary
            process.arguments = config.args
        }
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = stderrPipe

        // stderr 异步 read → 落盘
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            try? self?.stderrFileHandle?.write(contentsOf: data)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let newState: State
            switch proc.terminationReason {
            case .exit:           newState = .exited(code: proc.terminationStatus)
            case .uncaughtSignal: newState = .crashed(signal: proc.terminationStatus)
            @unknown default:     newState = .exited(code: -1)
            }
            self.lock.lock()
            self._state = newState
            let cbs = self.observers
            self.lock.unlock()
            try? self.stderrFileHandle?.close()
            self.stderrFileHandle = nil
            for cb in cbs { cb(newState) }
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrFileHandle?.close()
            stderrFileHandle = nil
            throw LaunchError.spawnFailed(reason: "\(error)")
        }

        lock.lock()
        _state = .running(pid: process.processIdentifier)
        lock.unlock()
    }

    /// poll 等 socket 文件出现 (or 进程早退立即 false). config.socketPathForReadyWait
    /// 为 nil 时立即返 false (业务方应不调).
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        guard let path = config.socketPathForReadyWait else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            switch state {
            case .exited, .crashed: return false
            default: break
            }
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// SIGTERM. runAsRoot=true 时 sudo 通常会 forward 给子进程.
    public func terminate() {
        let pid = process.processIdentifier
        if pid > 0 { _ = kill(pid, SIGTERM) }
    }

    /// SIGKILL. runAsRoot=true 时 SIGKILL 不能被 sudo forward, 子进程会孤儿;
    /// 兜底先 sudo + pkill -P 杀 sudo 的子进程, 再杀 sudo 自己.
    public func forceKill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if config.runAsRoot {
            // pkill -P <sudo-pid>: 杀 sudo 的所有子进程 (即真正的 sidecar binary)
            // 走 sudo 让 root 子进程也能被杀
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            pkill.arguments = ["-n", "/usr/bin/pkill", "-9", "-P", "\(pid)"]
            pkill.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            pkill.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? pkill.run()
            pkill.waitUntilExit()
        }
        _ = kill(pid, SIGKILL)
    }

    /// 阻塞等到子进程结束 (主要用于测试)
    public func waitUntilExit() {
        process.waitUntilExit()
    }
}
