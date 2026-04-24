// VMSession.swift
// GUI 进程内持有的单个 VM 运行会话:
//   - VMHandle (VZVirtualMachine 持有者)
//   - BundleLock (runtime 模式)
//   - IPC SocketServer (让 hvm-cli 也能 status/stop 本 VM)
//   - HVMView 单例 + ViewAttachment 用于独立/嵌入切换
//   - DisplayWindowController (当前独立窗口, 若有)
//   - 缩略图定时器
//
// 单进程方案下 (docs/GUI.md 选项 A), 主 App 直接起 VM, 不 fork VMHost.

import AppKit
import Foundation
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplay
import HVMIPC

public enum DisplayMode: Sendable, Equatable {
    case standalone   // 独立窗口
    case embedded     // 嵌入主窗口
    case hidden       // 运行中但用户未选中, 不显示
}

@MainActor
@Observable
public final class VMSession {
    public let bundleURL: URL
    public let config: VMConfig
    public let handle: VMHandle

    public private(set) var state: RunState = .stopped
    public private(set) var displayMode: DisplayMode = .hidden
    public private(set) var hostPid: Int32 = getpid()
    public private(set) var startedAt: Date?

    let attachment: ViewAttachment
    private var lock: BundleLock?
    private var ipcServer: SocketServer?
    private var displayWindow: DisplayWindowController?
    private var thumbnailTimer: Timer?
    private var observerToken: UUID?

    public init(bundleURL: URL, config: VMConfig) {
        self.bundleURL = bundleURL
        self.config = config
        self.handle = VMHandle(config: config, bundleURL: bundleURL)

        let view = HVMView(frame: .zero)
        self.attachment = ViewAttachment(view: view)
    }

    // MARK: - 生命周期

    public func start() async throws {
        guard state == .stopped else { return }

        // 1. 抢锁 + 准备 IPC
        try HVMPaths.ensure(HVMPaths.runDir)
        let socketURL = HVMPaths.socketPath(for: config.id)
        do {
            lock = try BundleLock(bundleURL: bundleURL, mode: .runtime, socketPath: socketURL.path)
        } catch {
            throw error
        }

        let server = SocketServer(socketPath: socketURL)
        self.ipcServer = server
        try server.start { [weak self] req in
            let box = ResponseBox(.failure(id: req.id, code: "ipc.internal", message: "未初始化"))
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = self?.handleIPC(req) ?? .failure(id: req.id, code: "ipc.no_session", message: "会话已销毁")
                sem.signal()
            }
            sem.wait()
            return box.value
        }

        // 2. 注册 state 观察者
        observerToken = handle.addStateObserver { [weak self] newState in
            Task { @MainActor in self?.onStateChanged(newState) }
        }

        // 3. 启动 VM
        startedAt = Date()
        do {
            try await handle.start()
        } catch {
            cleanup()
            throw error
        }
    }

    public func requestStop() throws {
        try handle.requestStop()
    }

    public func forceStop() async throws {
        try await handle.forceStop()
    }

    // MARK: - 显示模式

    /// 请求进入独立窗口态
    public func showStandalone() {
        switch displayMode {
        case .standalone: return
        case .embedded, .hidden: break
        }
        // 构建独立窗口, 把 view reparent 进去
        let title = "\(config.displayName) — \(config.guestOS.rawValue)"
        let window = DisplayWindowController(title: title, contentView: attachment.view)
        window.onRequestEmbed = { [weak self] in
            Task { @MainActor in self?.showEmbedded() }
        }
        if let content = window.window?.contentView {
            attachment.attach(to: content)
        }
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        displayWindow = window
        displayMode = .standalone
    }

    /// 请求进入嵌入态 (HVMView 回到主窗口右栏)
    public func showEmbedded() {
        displayWindow?.closeWithoutEmbedCallback()
        displayWindow = nil
        displayMode = .embedded
    }

    /// 不显示, 但 VM 继续运行
    public func hide() {
        displayWindow?.closeWithoutEmbedCallback()
        displayWindow = nil
        displayMode = .hidden
    }

    // MARK: - 内部

    private func onStateChanged(_ new: RunState) {
        self.state = new
        switch new {
        case .running:
            startThumbnailTimer()
        case .stopped, .error:
            stopThumbnailTimer()
            cleanup()
        default:
            break
        }
    }

    private func startThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                _ = ThumbnailGenerator.capture(from: self.attachment.view, to: self.bundleURL)
            }
        }
    }

    private func stopThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
    }

    private func cleanup() {
        if let token = observerToken {
            handle.removeStateObserver(token)
            observerToken = nil
        }
        ipcServer?.stop()
        ipcServer = nil
        lock?.release()
        lock = nil
        displayWindow?.closeWithoutEmbedCallback()
        displayWindow = nil
        attachment.detach()
        displayMode = .hidden
        startedAt = nil
    }

    // MARK: - IPC handler (GUI 进程内)

    private func handleIPC(_ req: IPCRequest) -> IPCResponse {
        switch req.op {
        case IPCOp.status.rawValue:
            let payload = IPCStatusPayload(
                state: stateString(state),
                id: config.id.uuidString,
                bundlePath: bundleURL.path,
                displayName: config.displayName,
                guestOS: config.guestOS.rawValue,
                cpuCount: config.cpuCount,
                memoryMiB: config.memoryMiB,
                pid: hostPid,
                startedAt: startedAt
            )
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "响应编码失败")
            }
            return .success(id: req.id, data: ["payload": json])

        case IPCOp.stop.rawValue:
            do {
                try handle.requestStop()
                return .success(id: req.id)
            } catch let e as HVMError {
                let uf = e.userFacing
                return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
            } catch {
                return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
            }

        case IPCOp.kill.rawValue:
            Task { @MainActor in
                try? await handle.forceStop()
            }
            return .success(id: req.id)

        default:
            return .failure(id: req.id, code: "ipc.unknown_op", message: "未知 op: \(req.op)")
        }
    }

    private func stateString(_ s: RunState) -> String {
        switch s {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .error(let msg): return "error:\(msg)"
        }
    }
}

// ResponseBox 定义在 HVMHostEntry.swift (同 module)
