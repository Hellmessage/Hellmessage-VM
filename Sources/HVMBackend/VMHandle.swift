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
        updateState(.starting)

        let vzConfig: VZVirtualMachineConfiguration
        do {
            vzConfig = try ConfigBuilder.build(from: config, bundleURL: bundleURL)
        } catch {
            updateState(.error("\(error)"))
            throw error
        }

        let vm = VZVirtualMachine(configuration: vzConfig)
        self.vm = vm
        let delegate = Delegate { [weak self] newState in
            Task { @MainActor in self?.onVZStateChanged(to: newState) }
        }
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
            self.vm = nil
            updateState(.error("\(error)"))
            throw error
        }
        updateState(.running)
    }

    public func requestStop() throws {
        guard let vm = self.vm else {
            throw HVMError.backend(.invalidTransition(from: "\(state)", to: "stopping"))
        }
        updateState(.stopping)
        do {
            try vm.requestStop()
        } catch {
            throw HVMError.backend(.vzInternal(description: "requestStop: \(error)"))
        }
    }

    public func forceStop() async throws {
        guard let vm = self.vm else { return }
        updateState(.stopping)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm.stop { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        } catch {
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
        case .stopped, .running, .paused:
            updateState(mapped)
        case .error(let msg):
            updateState(.error(msg))
        case .starting, .stopping:
            break
        }
    }
}

// MARK: - Delegate 适配器

private final class Delegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let onStateChange: ((VZVirtualMachine.State) -> Void)

    init(onStateChange: @escaping (VZVirtualMachine.State) -> Void) {
        self.onStateChange = onStateChange
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStateChange(.stopped)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStateChange(.error)
    }
}
