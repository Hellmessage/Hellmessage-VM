// HVMGuiProbe/ProbeServer.swift
// hvm-dbg ↔ HVM GUI 测试协议 (HDP-GUI) 服务端.
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md.
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

import Foundation
import AppKit
import HVMCore
import HVMIPC

@MainActor
public enum ProbeServer {
    private static let log = HVMLog.logger("guiprobe.server")
    nonisolated(unsafe) private static var server: SocketServer?

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

        default:
            return .failure(id: req.id,
                             code: "gui.unknown_op",
                             message: "unknown op '\(req.op)'")
        }
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
