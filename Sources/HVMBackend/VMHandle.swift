// HVMBackend/VMHandle.swift
// VM 一次运行会话的句柄. 持有 VZVirtualMachine, 所有 VZ API 在 MainActor 内串行调用
// 详见 docs/VZ_BACKEND.md
//
// 实现说明: 原设计用 Swift actor, 但 VZ 类 (VZVirtualMachine 等) 非 Sendable,
// 跨 actor 传递会触发 Swift 6 并发错误. VZ API 本来就要求主线程调用,
// 因此 @MainActor final class 既满足 VZ 约束又提供天然串行.

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

@MainActor
public final class VMHandle {
    public nonisolated let id: UUID
    public nonisolated let bundleURL: URL
    public nonisolated let config: VMConfig

    public private(set) var state: RunState = .stopped

    private var vm: VZVirtualMachine?
    private var delegate: Delegate?
    private var stateObservers: [UUID: (RunState) -> Void] = [:]
    /// guest virtio-console 桥接, hvm-dbg console / exec 通过它读写. VM 停止时 close.
    public private(set) var consoleBridge: ConsoleBridge?

    private static let log = HVMLog.logger("backend.vmhandle")

    /// VZ VM 实例 (只在 start 成功后非 nil). GUI 拿来挂给 VZVirtualMachineView 做渲染.
    public var virtualMachine: VZVirtualMachine? { vm }

    public init(config: VMConfig, bundleURL: URL) {
        self.id = config.id
        self.bundleURL = bundleURL
        self.config = config
    }

    // MARK: - 生命周期

    public func start() async throws {
        guard state == .stopped else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "starting"))
        }
        Self.log.info("VM start: \(self.config.displayName, privacy: .public) id=\(self.id.uuidString.prefix(8), privacy: .public) cpu=\(self.config.cpuCount) mem=\(self.config.memoryMiB)MiB os=\(self.config.guestOS.rawValue, privacy: .public)")
        updateState(.starting)

        let built: ConfigBuilder.BuildResult
        do {
            built = try ConfigBuilder.build(from: config, bundleURL: bundleURL)
        } catch {
            Self.log.error("ConfigBuilder.build 失败: \(error.localizedDescription, privacy: .public)")
            updateState(.error("\(error)"))
            throw error
        }

        let vm = VZVirtualMachine(configuration: built.vzConfig)
        self.vm = vm
        self.consoleBridge = built.consoleBridge
        let delegate = Delegate(
            onStateChange: { [weak self] newState in
                Task { @MainActor in self?.onVZStateChanged(to: newState) }
            },
            onStopWithError: { [weak self] message in
                Task { @MainActor in self?.onVZStoppedWithError(message: message) }
            }
        )
        self.delegate = delegate
        vm.delegate = delegate

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm.start { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: HVMError.backend(.vzInternal(description: "\(e)")))
                    }
                }
            }
        } catch {
            Self.log.error("VZVirtualMachine.start 失败: \(error.localizedDescription, privacy: .public)")
            self.vm = nil
            updateState(.error("\(error)"))
            throw error
        }
        Self.log.info("VM running: \(self.config.displayName, privacy: .public)")
        updateState(.running)
    }

    /// 请求 ACPI 软关机. vm 不存在 (从未 start / 已 stop) 抛 invalidTransition,
    /// 与 pause/resume/forceStop 行为一致, GUI/CLI 拿到清晰错误.
    public func requestStop() throws {
        guard let vm = self.vm else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "stopping"))
        }
        Self.log.info("VM requestStop (ACPI): \(self.config.displayName, privacy: .public)")
        updateState(.stopping)
        do {
            try vm.requestStop()
        } catch {
            Self.log.error("requestStop 失败: \(error.localizedDescription, privacy: .public)")
            throw HVMError.backend(.vzInternal(description: "requestStop: \(error)"))
        }
    }

    /// 强制停止. vm 不存在抛 invalidTransition (与 requestStop/pause/resume 统一语义).
    /// 调用方若想"幂等强停", 需要先用 self.state 判断.
    public func forceStop() async throws {
        guard let vm = self.vm else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "stopping"))
        }
        Self.log.warning("VM forceStop: \(self.config.displayName, privacy: .public)")
        updateState(.stopping)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm.stop { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        } catch {
            Self.log.error("forceStop 失败: \(error.localizedDescription, privacy: .public)")
            throw HVMError.backend(.vzInternal(description: "stop: \(error)"))
        }
        updateState(.stopped)
    }

    public func pause() async throws {
        guard let vm = self.vm else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "paused"))
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm.pause { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
        } catch {
            throw HVMError.backend(.vzInternal(description: "pause: \(error)"))
        }
        updateState(.paused)
    }

    public func resume() async throws {
        guard let vm = self.vm else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "running"))
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm.resume { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
        } catch {
            throw HVMError.backend(.vzInternal(description: "resume: \(error)"))
        }
        updateState(.running)
    }

    // MARK: - 观察者

    @discardableResult
    public func addStateObserver(_ handler: @escaping (RunState) -> Void) -> UUID {
        let token = UUID()
        stateObservers[token] = handler
        // 注意: 不立即投递当前 state.
        // 若注册时 state=.stopped, onStateChanged(.stopped) 的 cleanup 会 removeStateObserver
        // 导致后续真正的 .running/.starting 丢失. 调用方需要时主动读 self.state.
        return token
    }

    public func removeStateObserver(_ token: UUID) {
        stateObservers.removeValue(forKey: token)
    }

    // MARK: - 内部

    private func updateState(_ new: RunState) {
        state = new
        for (_, fn) in stateObservers { fn(new) }
    }

    private func onVZStateChanged(to vzState: VZVirtualMachine.State) {
        let mapped = RunState.from(vzState)
        // 避免覆盖 requestStop 设置的 .stopping 中间态: 只在 VZ 给出稳定态时更新
        switch mapped {
        case .stopped:
            consoleBridge?.close()
            consoleBridge = nil
            updateState(mapped)
        case .running, .paused:
            updateState(mapped)
        case .error(let msg):
            consoleBridge?.close()
            consoleBridge = nil
            updateState(.error(msg))
        case .starting, .stopping:
            break
        }
    }

    /// VZ delegate didStopWithError 回调: 把 VZ 给的真实错误信息塞进 RunState.error,
    /// 让 GUI/CLI 能展示具体原因 (而不是泛泛的 "VZ reported .error state").
    private func onVZStoppedWithError(message: String) {
        Self.log.error("VZ didStopWithError: \(self.config.displayName, privacy: .public): \(message, privacy: .public)")
        consoleBridge?.close()
        consoleBridge = nil
        updateState(.error(message))
    }
}

// MARK: - Delegate 适配器

private final class Delegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let onStateChange: ((VZVirtualMachine.State) -> Void)
    private let onStopWithError: ((String) -> Void)

    init(
        onStateChange: @escaping (VZVirtualMachine.State) -> Void,
        onStopWithError: @escaping (String) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onStopWithError = onStopWithError
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStateChange(.stopped)
    }

    /// VZ 报告 fatal error. 把 error.localizedDescription 透传给 VMHandle, 写进 RunState.error
    /// 而不是丢失. 常见原因: 磁盘 IO 失败 / config 不支持 / firmware 验证失败 等.
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStopWithError(error.localizedDescription)
    }
}
