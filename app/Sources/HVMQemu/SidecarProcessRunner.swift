// HVMQemu/SidecarProcessRunner.swift
// 公共 sidecar 子进程编排. QemuProcessRunner / SwtpmRunner 都是
// 它的 thin wrapper (保留各自 public API, 内部转发到这里).
//
// 抽出原因: 多个 Runner 状态机 / lifecycle / stderr 落盘 / observer 几乎逐字相同 (>75%
// 复制); bug 修一处忘另一处的风险高. 抽到一个 class 后, 通过 Config 控制差异化行为
// (是否走 sudo, 是否带 socket-ready poll), 不同业务都跑同一份代码.
//
// 注: 老的 vmnet fd 透传路径 (extraFdConnections + posix_spawn) 已下线 — socket_vmnet
//     桥接逻辑切到 hell-vm 风格新方案后, QEMU 直接 -netdev stream 连 daemon, 不需要
//     父进程 socket()+connect() 把 fd 透传给子进程. 老路径 + posix_spawn 整段删除.
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
            // 显式清 stderr readabilityHandler — 老逻辑只靠 availableData.isEmpty (EOF)
            // 触发 self-clear, 但 SIGKILL 路径 kernel 可能不送干净 EOF, 读线程会陷入轮询.
            // 进程 termination 是确定性信号, 在这里清最稳.
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
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

    /// 强制结束子进程. runAsRoot=true 时 SIGKILL 不能被 sudo forward, 走 pkill -P
    /// 杀 sudo 的真正 binary 子进程.
    ///
    /// 双段杀策略 (修 swtpm NVRAM 腰斩 race, 见 docs/v2/01-P0-immediate.md #3):
    ///   1. pkill -15 (SIGTERM) 给 swtpm 100ms 关 NVRAM + flush
    ///   2. pkill -9 (SIGKILL) 兜底
    ///   3. 最后 process.waitUntilExit 等 sudo wrapper 真退 — 此时 kernel 已 reap
    ///      子进程, NVRAM fd 已关, 调用方可放心 release lock.
    /// pkill 命令本身只发信号不等子进程死, 所以 pkill.waitUntilExit 不能保证 swtpm
    /// 已 reap; 只有 process.waitUntilExit (等 sudo 自己死) 才能.
    public func forceKill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if config.runAsRoot {
            runSudoPkill(parentPid: pid, signal: 15)
            usleep(100_000)  // 100ms 让 swtpm 处理 SIGTERM (关 NVRAM 文件)
            runSudoPkill(parentPid: pid, signal: 9)
        }
        _ = kill(pid, SIGKILL)
        // 等 sudo wrapper 真退. 此时 swtpm 已被 kernel reap, NVRAM 写完成或丢弃,
        // 调用方 lock.release() 后不会再有 swtpm 写一帧腰斩 NVRAM 数据的风险.
        process.waitUntilExit()
    }

    /// sudo + pkill -<sig> -P <ppid>: 杀指定父 pid 下的所有子进程.
    private func runSudoPkill(parentPid: Int32, signal: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pkill", "-\(signal)", "-P", "\(parentPid)"]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? p.run()
        p.waitUntilExit()
    }

    /// 阻塞等到子进程结束 (主要用于测试).
    public func waitUntilExit() {
        process.waitUntilExit()
    }
}
