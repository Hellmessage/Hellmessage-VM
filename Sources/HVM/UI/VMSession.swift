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
    case embedded     // 嵌入主窗口 (M2 唯一模式)
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

    public let attachment: ViewAttachment
    private var lock: BundleLock?
    private var ipcServer: SocketServer?
    private var thumbnailTimer: Timer?
    private var observerToken: UUID?
    /// 最近一次 dbg.screenshot 拿到的 frame sha256, 给 dbg.status 上报让 AI agent 判断画面有无变化
    private var lastFrameSha256: String?

    /// VM 自然结束 (.stopped / .error) 时回调. AppModel 注入 sessionDidEnd 以同步列表/侧边栏.
    /// 同进程模式下唯一的 stop → list 刷新通知点; 不挂会导致侧边栏 running 状态停留.
    public var onEnded: (@MainActor (UUID) -> Void)?

    public init(bundleURL: URL, config: VMConfig) {
        self.bundleURL = bundleURL
        self.config = config
        self.handle = VMHandle(config: config, bundleURL: bundleURL)

        let view = HVMView(frame: .zero)
        self.attachment = ViewAttachment(view: view)

        // HVMView 进入 window 时触发绑定, 这是 VZ Metal drawable 创建的必要时机之一.
        // 与 .task 调用一起形成双保险: 任一条件满足都能绑上.
        view.onEnteredWindow = { [weak self] in
            Task { @MainActor in self?.bindVMToView() }
        }
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
        // 注意: 不在这里设 view.virtualMachine, 因为 view 此刻还不在 window hierarchy,
        // VZ 的 Metal display 只在 view 进入 window 时创建 (Apple docs).
        // 实际赋值在 showStandalone/showEmbedded 里 view attach 到容器后做.
    }

    public func requestStop() throws {
        try handle.requestStop()
    }

    public func forceStop() async throws {
        try await handle.forceStop()
    }

    // MARK: - 显示模式 (M2 只支持嵌入)

    /// 标记为嵌入态. 实际 view attach 由 DetailPanel 的 EmbeddedVMContent 通过 NSViewRepresentable 处理.
    public func showEmbedded() {
        displayMode = .embedded
    }

    /// 不显示, 但 VM 继续运行
    public func hide() {
        displayMode = .hidden
    }

    /// DetailPanel 里 EmbeddedVMContent 进入 window 后调用, 绑定 VZ VM 到 view.
    /// 时机非常关键: VZVirtualMachineView 的 Metal display 仅在 view 进入 window hierarchy
    /// 且 virtualMachine 属性被 set 时创建 (Apple docs).
    public func bindVMToView() {
        guard let vm = handle.virtualMachine else { return }
        if attachment.view.virtualMachine !== vm {
            attachment.view.virtualMachine = vm
        }
    }

    // MARK: - 内部

    private func onStateChanged(_ new: RunState) {
        self.state = new
        switch new {
        case .running:
            // 兜底: VM 正式 running 时再绑一次 view.virtualMachine.
            // 若 .task 或 viewDidMoveToWindow 早于 vm 创建, 这里补救.
            bindVMToView()
            startThumbnailTimer()
        case .stopped, .error:
            stopThumbnailTimer()
            cleanup()
            onEnded?(config.id)
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
        attachment.view.virtualMachine = nil
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

        case IPCOp.dbgScreenshot.rawValue:
            return handleDbgScreenshot(req)

        case IPCOp.dbgStatus.rawValue:
            return handleDbgStatus(req)

        case IPCOp.dbgKey.rawValue:
            return handleDbgKey(req)

        default:
            return .failure(id: req.id, code: "ipc.unknown_op", message: "未知 op: \(req.op)")
        }
    }

    private func handleDbgScreenshot(_ req: IPCRequest) -> IPCResponse {
        guard state == .running || state == .paused else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(state))), 无法截图")
        }
        guard let shot = ScreenCapture.capturePNG(from: attachment.view) else {
            return .failure(id: req.id, code: "dbg.frame_unavailable",
                            message: "view 还未渲染或 frame buffer 为空")
        }
        lastFrameSha256 = shot.sha256
        let payload = IPCDbgScreenshotPayload(
            pngBase64: shot.data.base64EncodedString(),
            widthPx: shot.widthPx,
            heightPx: shot.heightPx,
            sha256: shot.sha256
        )
        guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "screenshot payload 编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
    }

    private func handleDbgKey(_ req: IPCRequest) -> IPCResponse {
        guard state == .running else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(state))), 无法注入按键")
        }
        do {
            if let text = req.args["text"] {
                try KeyboardEmulator.typeText(text, into: attachment.view)
            } else if let press = req.args["press"] {
                try KeyboardEmulator.pressKeys(press, into: attachment.view)
            } else {
                return .failure(id: req.id, code: "config.missing_field",
                                message: "需要 args.text 或 args.press")
            }
            return .success(id: req.id)
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
        }
    }

    private func handleDbgStatus(_ req: IPCRequest) -> IPCResponse {
        // guest framebuffer 分辨率: 当前 ConfigBuilder 硬编码值 (Linux 1024x768, macOS 1920x1080).
        // 后续若 VMConfig 引入 displaySpec, 这里改成读 config.
        let (w, h): (Int, Int)
        switch config.guestOS {
        case .linux: (w, h) = (1024, 768)
        case .macOS: (w, h) = (1920, 1080)
        }
        let payload = IPCDbgStatusPayload(
            state: stateString(state),
            guestWidthPx: w,
            guestHeightPx: h,
            lastFrameSha256: lastFrameSha256,
            consoleAgentOnline: false  // M5 phase 5 接入 console 通道后改 true
        )
        guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "dbg status payload 编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
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
