// HVMQemu/SwtpmRunner.swift
// swtpm 子进程包装. 与 QemuProcessRunner 同形态, 但少 QMP 之类的复杂控制面.
//
// 与 QemuProcessRunner 的差异:
//   - 不接 QMP / 任何控制协议; 终止靠 SIGTERM 或 swtpm 自己 --terminate
//   - 提供 waitForSocketReady: ctrl socket 文件就绪后才让 QEMU 启动
//   - 状态机相同: .idle → .running → .exited / .crashed

import Foundation
import HVMCore

public final class SwtpmRunner: @unchecked Sendable {

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

    public let binary: URL
    public let args: [String]
    /// 可选: stderr tee 到 file (append). 主要用于诊断 swtpm 启动失败
    public let stderrLog: URL?
    /// ctrl socket 路径 (与 args 中的 --ctrl 同步; runner 知道路径以便 waitForSocketReady)
    public let ctrlSocketPath: String

    private let lock = NSLock()
    private var _state: State = .idle
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrFileHandle: FileHandle?
    private var observers: [(State) -> Void] = []

    public init(binary: URL, args: [String], ctrlSocketPath: String, stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.ctrlSocketPath = ctrlSocketPath
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

        process.executableURL = binary
        process.arguments = args
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

    /// 轮询等 ctrl socket 文件出现 (swtpm bind 后才能让 QEMU 连).
    /// 同时若 swtpm 提前退出 (例 stateDir 无写权限) 立即 false.
    public func waitForSocketReady(timeoutSec: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        while Date() < deadline {
            switch state {
            case .exited, .crashed: return false
            default: break
            }
            if FileManager.default.fileExists(atPath: ctrlSocketPath) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// SIGTERM, swtpm 收到后清理并退出
    public func terminate() {
        let pid = process.processIdentifier
        if pid > 0 {
            _ = kill(pid, SIGTERM)
        }
    }

    /// SIGKILL, 强杀
    public func forceKill() {
        let pid = process.processIdentifier
        if pid > 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    public func waitUntilExit() {
        process.waitUntilExit()
    }
}
