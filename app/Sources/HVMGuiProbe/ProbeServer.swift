// HVMGuiProbe/ProbeServer.swift
// hvm-dbg ↔ HVM GUI 测试协议 (HDP-GUI) 服务端.
// HDP-GUI 协议.
//
// 跨 module 依赖说明: 引 HVMDisplayQemu 拿 FramebufferHostView (debug.simulate-drop /
// debug.show-drop-overlay 直接戳 view 测拖放通路).
//
// 架构: SocketServer (HVMIPC) 包装, 跑在 HVM 主进程内, 监听
//       ~/Library/Application Support/HVM/run/hvm-dbg-gui.sock
//
// 启用: 仅当 env HVM_GUI_PROBE=1 时 install (release build 默认不启).
//
// op 集 (PR-G1 仅 screenshot; G2-G5 扩):
//   - gui.screenshot   截当前主窗口 + 任何弹层 → PNG (base64)
//   - gui.ping         健康探测 (PR-G1 加, 用来跑通往返)
//   - gui.list         列控件 tree (PR-G2)
//   - gui.click        点 identifier (PR-G3)
//   - gui.type         输文字 (PR-G3)
//   - gui.keypress     发 keystroke (PR-G3)
//   - gui.dialog       当前 dialog 名 (PR-G3 / G4)
//   - gui.event.subscribe 长连接事件流 (PR-G4)
//   - debug.trigger-error  仅测试用; 给 ErrorPresenter push 一个测试 ErrorDialog
//                          (验 dialog z-order / 显示行为, 不依赖真实业务失败路径)

import Foundation
import AppKit
import HVMCore
import HVMDisplayQemu
import HVMIPC

/// 弱引用包装, 给 ProbeServer 拿一个 type-erased `present(_: ErrorDialogModel-ish)`.
/// 避开 ProbeServer 直接依赖 ErrorPresenter (它在 HVM target, ProbeServer 在 HVMGuiProbe target).
@MainActor
public protocol ProbeErrorPresenter: AnyObject {
    func presentTestError(title: String, message: String, details: String?, hint: String?)
    /// 主动 dismiss 当前 dialog (验 dismiss 路径 + framebuffer 恢复)
    func dismissCurrentTestError()
    /// 主窗口拉到前台 (HVM 默认 close=hide 到 accessory, 测试需要主动 show)
    func showMainWindow()
}

@MainActor
public enum ProbeServer {
    private static let log = HVMLog.logger("guiprobe.server")
    nonisolated(unsafe) private static var server: SocketServer?
    /// 用于 debug.trigger-error. HVMApp 启动时通过 setTestErrorPresenter 注入.
    nonisolated(unsafe) private static weak var errorPresenter: ProbeErrorPresenter?

    /// 给 HVMApp 在启动时注入 ErrorPresenter 适配器 (HVMAppDelegate 起 ProbeServer 前调).
    public static func setTestErrorPresenter(_ presenter: ProbeErrorPresenter?) {
        errorPresenter = presenter
    }

    /// 默认 socket 路径
    public static var defaultSocketPath: URL {
        HVMPaths.runDir.appendingPathComponent("hvm-dbg-gui.sock")
    }

    /// 是否启用 (HVM_GUI_PROBE=1 触发)
    public static var enabledByEnv: Bool {
        ProcessInfo.processInfo.environment["HVM_GUI_PROBE"] == "1"
    }

    /// 启动 server. 重复调用幂等.
    public static func start() {
        guard server == nil else { return }
        guard enabledByEnv else {
            log.info("ProbeServer not started (HVM_GUI_PROBE != 1)")
            return
        }

        let path = defaultSocketPath
        do {
            try HVMPaths.ensure(path.deletingLastPathComponent())
        } catch {
            log.error("ProbeServer ensure run dir failed: \(String(describing: error), privacy: .public)")
            return
        }

        let s = SocketServer(socketPath: path)
        do {
            try s.start { req in
                // SocketServer handler 在 IPC 池线程; 必须 hop 到 MainActor 跑实际逻辑 (操作 NSWindow / SwiftUI state 必须主线程).
                // 历史: 之前用 DispatchQueue.main.sync — 工作原理上从背景线程调 main.sync 不会自死锁,
                // 但若主线程同步调用又依赖 IPC 回包的代码出现, 会形成跨线程死锁循环. 改 Task @MainActor + semaphore
                // 不破坏阻塞语义但避开 main.sync 这把脆性锁
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var captured: IPCResponse = .failure(
                    id: req.id, code: "gui.internal", message: "MainActor handler 未返回")
                Task { @MainActor in
                    captured = handleRequest(req)
                    sem.signal()
                }
                sem.wait()
                return captured
            }
            server = s
            log.info("ProbeServer started: \(path.path, privacy: .public)")
        } catch {
            log.error("ProbeServer start failed: \(String(describing: error), privacy: .public)")
        }
    }

    public static func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - dispatcher

    /// 主线程入口 — 操作 NSWindow / NSView 必须主线程.
    @MainActor
    private static func handleRequest(_ req: IPCRequest) -> IPCResponse {
        switch req.op {
        case "gui.ping":
            return .success(id: req.id, data: ["pong": "true",
                                                "version": "\(HVMVersion.displayString)"])

        case "gui.screenshot":
            return handleScreenshot(req)

        case "gui.list":
            return handleList(req)

        case "gui.click":
            return handleClick(req)

        case "gui.type":
            return handleType(req)

        case "gui.read":
            return handleRead(req)

        case "debug.trigger-error":
            return handleTriggerError(req)

        case "debug.dismiss-error":
            return handleDismissError(req)

        case "debug.show-window":
            errorPresenter?.showMainWindow()
            return .success(id: req.id)

        case "debug.simulate-drop":
            return handleSimulateDrop(req)

        case "debug.show-drop-overlay":
            return handleShowDropOverlay(req)

        default:
            return .failure(id: req.id,
                             code: "gui.unknown_op",
                             message: "unknown op '\(req.op)'")
        }
    }

    /// 仅测试用. 通过注入的 ErrorPresenter 适配器 push 一个测试 ErrorDialog,
    /// 让 hvm-dbg 自动化测试验证 dialog z-order / 显示行为 (不依赖真实业务失败路径).
    @MainActor
    private static func handleTriggerError(_ req: IPCRequest) -> IPCResponse {
        guard let presenter = errorPresenter else {
            return .failure(id: req.id, code: "debug.no_presenter",
                             message: "ErrorPresenter 未注入; HVMApp 启动顺序错乱?")
        }
        let title = req.args["title"] ?? "Test Error"
        let message = req.args["message"] ?? "Test error from gui probe (debug.trigger-error)"
        let details = req.args["details"]
        let hint = req.args["hint"]
        presenter.presentTestError(title: title, message: message, details: details, hint: hint)
        return .success(id: req.id, data: ["triggered": "true"])
    }

    /// 测试用 — 找当前 NSApp 第一个可见 FramebufferHostView (主嵌入或 detached 都行).
    /// 用 BFS 遍历所有 visible window 的 contentView subview tree.
    @MainActor
    private static func findFramebufferHostView() -> FramebufferHostView? {
        for window in NSApp.windows where window.isVisible {
            guard let root = window.contentView else { continue }
            var stack: [NSView] = [root]
            while let v = stack.popLast() {
                if let fb = v as? FramebufferHostView { return fb }
                stack.append(contentsOf: v.subviews)
            }
        }
        return nil
    }

    /// 测试用 — 直接调 FramebufferHostView.onFilePaste(urls) 模拟拖放完成 (绕开 AppKit drag
    /// session 复杂度, 走跟 drag drop / Cmd+V 同一闭包). args.paths = JSON 数组.
    @MainActor
    private static func handleSimulateDrop(_ req: IPCRequest) -> IPCResponse {
        guard let pathsJSON = req.args["paths"],
              let data = pathsJSON.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty else {
            return .failure(id: req.id, code: "debug.bad_args",
                             message: "需要 args.paths (JSON 数组)")
        }
        guard let fb = findFramebufferHostView() else {
            return .failure(id: req.id, code: "debug.no_fb_view",
                             message: "找不到可见 FramebufferHostView (VM 未跑 / 选中?)")
        }
        guard let onFilePaste = fb.onFilePaste else {
            return .failure(id: req.id, code: "debug.no_paste_closure",
                             message: "fbView 未注入 onFilePaste 闭包")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        onFilePaste(urls)
        return .success(id: req.id, data: ["dispatched": "\(urls.count)"])
    }

    /// 测试用 — 主动切 dropOverlay 显隐 (visual snapshot 验证). args.visible="true"/"false",
    /// args.count = N (显示时填的文件数文案).
    @MainActor
    private static func handleShowDropOverlay(_ req: IPCRequest) -> IPCResponse {
        guard let fb = findFramebufferHostView() else {
            return .failure(id: req.id, code: "debug.no_fb_view",
                             message: "找不到可见 FramebufferHostView")
        }
        let visible = req.args["visible"]?.lowercased() == "true"
        let count = Int(req.args["count"] ?? "1") ?? 1
        if visible {
            fb.probeShowDropOverlay(count: count)
        } else {
            fb.probeHideDropOverlay()
        }
        return .success(id: req.id)
    }

    /// 主动 dismiss 当前 dialog. 给 hvm-dbg 自动化测试 dismiss 后 framebuffer 恢复用.
    @MainActor
    private static func handleDismissError(_ req: IPCRequest) -> IPCResponse {
        guard let presenter = errorPresenter else {
            return .failure(id: req.id, code: "debug.no_presenter",
                             message: "ErrorPresenter 未注入")
        }
        presenter.dismissCurrentTestError()
        return .success(id: req.id, data: ["dismissed": "true"])
    }

    @MainActor
    private static func handleList(_ req: IPCRequest) -> IPCResponse {
        let entries = ViewRegistry.list()
        return .encoded(id: req.id, payload: entries, kind: "gui.list")
    }

    @MainActor
    private static func handleClick(_ req: IPCRequest) -> IPCResponse {
        guard let id = req.args["identifier"] else {
            return .failure(id: req.id, code: "gui.missing_arg",
                             message: "gui.click 需要 args.identifier")
        }
        if ViewRegistry.click(identifier: id) {
            return .success(id: req.id, data: ["clicked": id])
        }
        return .failure(id: req.id, code: "gui.identifier_not_found",
                         message: "no clickable control with identifier '\(id)' (use gui.list 看可用 ids)")
    }

    @MainActor
    private static func handleType(_ req: IPCRequest) -> IPCResponse {
        guard let id = req.args["identifier"] else {
            return .failure(id: req.id, code: "gui.missing_arg",
                             message: "gui.type 需要 args.identifier")
        }
        let text = req.args["text"] ?? ""
        if ViewRegistry.type(identifier: id, text: text) {
            return .success(id: req.id, data: ["typed": id])
        }
        return .failure(id: req.id, code: "gui.identifier_not_found",
                         message: "no textField/toggle with identifier '\(id)'")
    }

    @MainActor
    private static func handleRead(_ req: IPCRequest) -> IPCResponse {
        guard let id = req.args["identifier"] else {
            return .failure(id: req.id, code: "gui.missing_arg",
                             message: "gui.read 需要 args.identifier")
        }
        if let value = ViewRegistry.read(identifier: id) {
            return .success(id: req.id, data: ["value": value])
        }
        return .failure(id: req.id, code: "gui.identifier_not_found",
                         message: "no readable control with identifier '\(id)'")
    }

    @MainActor
    private static func handleScreenshot(_ req: IPCRequest) -> IPCResponse {
        guard let png = ScreenshotRenderer.captureMainWindow() else {
            return .failure(id: req.id,
                             code: "gui.screenshot_failed",
                             message: "captureMainWindow 返 nil (主窗口未就绪 / contentView 缓存失败)")
        }
        let b64 = png.base64EncodedString()
        return .success(id: req.id, data: ["png_base64": b64,
                                            "byte_size": "\(png.count)"])
    }
}
