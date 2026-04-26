// HVMQemu/QemuProcessRunner.swift
// 轻量 Process 包装: 启动 qemu-system-aarch64, 捕获 stderr 落盘, 优雅 / 强制停止.
//
// 不做的事:
//   - 不构造 argv (那是 QemuArgsBuilder 的责任)
//   - 不发 QMP 命令做 ACPI shutdown (那是 QmpClient 的责任, 下个 commit)
//   - 不绑定到 VMHandle (集成留给后续 commit)
//
// 状态机:
//   .idle → .running(pid) → .exited(code) | .crashed(signal)

import Foundation
import HVMCore

public final class QemuProcessRunner: @unchecked Sendable {

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
    /// 可选: stderr 同时 tee 到此文件 (append). 不传则丢弃
    public let stderrLog: URL?

    private let lock = NSLock()
    private var _state: State = .idle
    private let process = Process()
    private let stderrPipe = Pipe()
    private var stderrFileHandle: FileHandle?
    private var observers: [(State) -> Void] = []

    public init(binary: URL, args: [String], stderrLog: URL? = nil) {
        self.binary = binary
        self.args = args
        self.stderrLog = stderrLog
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

    /// 启动 QEMU 子进程. 成功后 state 转 .running(pid).
    /// 不阻塞; terminationHandler 异步更新 state 到 .exited / .crashed.
    public func start() throws {
        lock.lock()
        guard case .idle = _state else {
            lock.unlock()
            throw LaunchError.alreadyStarted
        }
        lock.unlock()

        // stderr 落盘准备 (append 模式, 跨 start 累积)
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
            case .exit:
                newState = .exited(code: proc.terminationStatus)
            case .uncaughtSignal:
                newState = .crashed(signal: proc.terminationStatus)
            @unknown default:
                newState = .exited(code: -1)
            }
            self.lock.lock()
            self._state = newState
            let cbs = self.observers
            self.lock.unlock()

            // 关 stderr 文件 (在 readabilityHandler 之后)
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

    /// SIGTERM: 让 QEMU 走自己的清理 (但 QEMU 收到 SIGTERM 不走 ACPI powerdown,
    /// 直接退出; ACPI 优雅关机走 QmpClient 的 system_powerdown). 此 API 用于
    /// "强制中断子进程" 而非 "guest 优雅关机".
    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// SIGKILL: 强杀, 对应 hvm-cli kill 语义
    public func forceKill() {
        if process.isRunning {
            // Foundation.Process 没暴露 kill(2), 用 POSIX
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// 阻塞等到子进程结束 (主要用于测试)
    public func waitUntilExit() {
        process.waitUntilExit()
    }
}
