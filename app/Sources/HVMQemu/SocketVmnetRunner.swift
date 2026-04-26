// HVMQemu/SocketVmnetRunner.swift
// socket_vmnet 子进程包装. 与 SwtpmRunner 同形态, 关键差异: 必须通过 sudo 拉起.
//
// 调用方负责:
//   1. 通过 SudoersChecker 确认 NOPASSWD 配置已就绪 (否则交互式 sudo 会卡 GUI)
//   2. SocketVmnetPaths.locate() 拿 socket_vmnet 二进制
//   3. SocketVmnetArgsBuilder.build() 拿 argv
//   4. SocketVmnetRunner(binary:, args:, ...).start()
//
// 进程模型: /usr/bin/sudo -n <socket_vmnet> <args...>
// -n: 不允许 prompt; sudoers 没 NOPASSWD 立即失败 (避免 hang).

import Foundation
import HVMCore

public final class SocketVmnetRunner: @unchecked Sendable {

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

    /// socket_vmnet 二进制 (由 SocketVmnetPaths.locate() 解析). Runner 内部会用 sudo -n 调.
    public let binary: URL
    /// SocketVmnetArgsBuilder.build() 的输出
    public let args: [String]
    /// socket_vmnet 监听的 unix socket 路径 (跟 args 中的最后一个参数同步; 用于 waitForSocketReady)
    public let socketPath: String
    /// 可选: stderr tee 到 file (主要用于诊断 sudo / vmnet 启动失败)
    public let stderrLog: URL?

    private let lock = NSLock()
    private var _state: State = .idle
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrFileHandle: FileHandle?
    private var observers: [(State) -> Void] = []

    public init(binary: URL, args: [String], socketPath: String, stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.socketPath = socketPath
        self.stderrLog = stderrLog
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public func addStateObserver(_ cb: @escaping (State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(cb)
    }

    /// 启动 socket_vmnet (通过 sudo -n <binary> <args>).
    /// sudoers NOPASSWD 未配会立即非 0 退出 (sudo -n).
    public func start() throws {
        lock.lock()
        guard case .idle = _state else {
            lock.unlock()
            throw LaunchError.alreadyStarted
        }
        lock.unlock()

        if let logURL = stderrLog {
            let fm = FileManager.default
            try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            stderrFileHandle = try? FileHandle(forWritingTo: logURL)
            try? stderrFileHandle?.seekToEnd()
        }

        // /usr/bin/sudo -n <binary> <args...>
        // -n: non-interactive; sudoers NOPASSWD 没配会立即退非 0, 不会 hang
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", binary.path] + args
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = stderrPipe

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

    /// poll 等 socket 文件出现; 进程早退立即 false.
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            switch state {
            case .exited, .crashed: return false
            default: break
            }
            if FileManager.default.fileExists(atPath: socketPath) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// SIGTERM 给 sudo, sudo 通常会 forward 给子进程 socket_vmnet 让其干净退.
    public func terminate() {
        let pid = process.processIdentifier
        if pid > 0 {
            _ = kill(pid, SIGTERM)
        }
    }

    /// SIGKILL 给 sudo. 注意: SIGKILL 不可被 sudo 拦截 forward, socket_vmnet (root 子进程)
    /// 可能孤儿. 兜底用 pkill -P 杀 sudo 的子进程, 再 kill sudo 本身.
    /// 后续可改成读取 --pidfile 直接 kill socket_vmnet pid (更精确).
    public func forceKill() {
        let pid = process.processIdentifier
        if pid > 0 {
            // pkill -P <sudo-pid>: 杀所有以 sudo 为父的进程 (即 socket_vmnet)
            // 走 sudo 让 root 子进程也能被杀
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            pkill.arguments = ["-n", "/usr/bin/pkill", "-9", "-P", "\(pid)"]
            pkill.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            pkill.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try? pkill.run()
            pkill.waitUntilExit()
            // 再杀 sudo 自己 (它可能因 -n + 子进程已死而退出)
            _ = kill(pid, SIGKILL)
        }
    }

    public func waitUntilExit() {
        process.waitUntilExit()
    }
}
