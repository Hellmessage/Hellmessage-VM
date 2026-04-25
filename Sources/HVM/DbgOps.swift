// HVM/DbgOps.swift
// hvm-dbg IPC op 的共享实现, 给 GUI (VMSession) 和 headless (HVMHostEntry/HostState)
// 复用. 状态: 只有 lastFrameSha256 一个缓存, 其他都从外部 view + state 拿.
//
// 关键设计: 不持有 VM/state 引用, 用 closure 在每次 handle 时取当前 state.
// 这样 GUI 模式 (state 来自 RunState observer) 和 headless 模式 (state 来自 VMHandle.state)
// 都能塞.

import AppKit
import Foundation
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplay
import HVMIPC

@MainActor
public final class DbgOps {
    private let view: HVMView
    private let guestOS: GuestOSType
    private let stateProvider: () -> RunState
    private var lastFrameSha256: String? = nil

    public init(view: HVMView, guestOS: GuestOSType, stateProvider: @escaping () -> RunState) {
        self.view = view
        self.guestOS = guestOS
        self.stateProvider = stateProvider
    }

    /// 试图处理 dbg.* op. 不认的 op 返回 nil 让调用方做兜底.
    public func tryHandle(_ req: IPCRequest) -> IPCResponse? {
        switch req.op {
        case IPCOp.dbgScreenshot.rawValue: return handleScreenshot(req)
        case IPCOp.dbgStatus.rawValue:     return handleStatus(req)
        case IPCOp.dbgKey.rawValue:        return handleKey(req)
        case IPCOp.dbgMouse.rawValue:      return handleMouse(req)
        case IPCOp.dbgOcr.rawValue:        return handleOcr(req)
        case IPCOp.dbgFindText.rawValue:   return handleFindText(req)
        default: return nil
        }
    }

    // MARK: - 各 op

    private func handleScreenshot(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        guard s == .running || s == .paused else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(s))), 无法截图")
        }
        // 截图给 Claude / 通用消费场景: cap 最长边 1568px.
        // Retina 上 1920x1080 离屏 window 抓出来本是 3840x2160, 超 Claude API
        // many-image 2000px 单边上限. 1568 是 Anthropic 推荐尺寸, 兼顾质量与体积.
        // OCR / find-text 走另一条路, 不传 maxEdge, 保留全分辨率以维持识别精度.
        guard let shot = ScreenCapture.capturePNG(from: view, maxEdge: 1568) else {
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

    private func handleStatus(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        let (w, h) = guestFramebufferSize()
        let payload = IPCDbgStatusPayload(
            state: stateString(s),
            guestWidthPx: w,
            guestHeightPx: h,
            lastFrameSha256: lastFrameSha256,
            consoleAgentOnline: false
        )
        guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
            return .failure(id: req.id, code: "ipc.encode_failed", message: "dbg status payload 编码失败")
        }
        return .success(id: req.id, data: ["payload": json])
    }

    private func handleKey(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        guard s == .running else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(s))), 无法注入按键")
        }
        do {
            if let text = req.args["text"] {
                try KeyboardEmulator.typeText(text, into: view)
            } else if let press = req.args["press"] {
                try KeyboardEmulator.pressKeys(press, into: view)
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

    private func handleMouse(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        guard s == .running else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(s))), 无法注入鼠标")
        }
        let (gw, gh) = guestFramebufferSize()
        let guestSize = CGSize(width: gw, height: gh)
        let button = MouseEmulator.Button(rawValue: req.args["button"] ?? "left") ?? .left
        do {
            switch req.args["op"] ?? "" {
            case "move":
                let p = try parsePoint(req.args["x"], req.args["y"])
                try MouseEmulator.move(to: p, guestSize: guestSize, into: view)
            case "click":
                let p = try parsePoint(req.args["x"], req.args["y"])
                try MouseEmulator.click(at: p, guestSize: guestSize, button: button, into: view)
            case "double-click":
                let p = try parsePoint(req.args["x"], req.args["y"])
                try MouseEmulator.doubleClick(at: p, guestSize: guestSize, button: button, into: view)
            case "drag":
                let a = try parsePoint(req.args["x"],  req.args["y"])
                let b = try parsePoint(req.args["x2"], req.args["y2"])
                try MouseEmulator.drag(from: a, to: b, guestSize: guestSize, button: button, into: view)
            default:
                return .failure(id: req.id, code: "config.invalid_enum",
                                message: "未知 mouse.op: \(req.args["op"] ?? "(nil)")")
            }
            return .success(id: req.id)
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
        }
    }

    private func handleOcr(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        guard s == .running || s == .paused else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(s)))")
        }
        guard let shot = ScreenCapture.capturePNG(from: view) else {
            return .failure(id: req.id, code: "dbg.frame_unavailable",
                            message: "view 还未渲染或 frame buffer 为空")
        }
        lastFrameSha256 = shot.sha256
        var region: CGRect? = nil
        if let xs = req.args["x"], let ys = req.args["y"],
           let ws = req.args["w"], let hs = req.args["h"],
           let x = Double(xs), let y = Double(ys),
           let w = Double(ws), let h = Double(hs) {
            region = CGRect(x: x, y: y, width: w, height: h)
        }
        do {
            let items = try OCREngine.recognize(pngData: shot.data, region: region)
            let payload = IPCDbgOcrPayload(
                widthPx: shot.widthPx,
                heightPx: shot.heightPx,
                texts: items.map { IPCDbgOcrPayload.Item(
                    x: $0.x, y: $0.y, width: $0.width, height: $0.height,
                    text: $0.text, confidence: $0.confidence
                ) }
            )
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "ocr payload 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
        }
    }

    private func handleFindText(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        guard s == .running || s == .paused else {
            return .failure(id: req.id, code: "dbg.vm_not_running",
                            message: "VM 未运行 (state=\(stateString(s)))")
        }
        guard let query = req.args["query"], !query.isEmpty else {
            return .failure(id: req.id, code: "config.missing_field", message: "需要 args.query")
        }
        guard let shot = ScreenCapture.capturePNG(from: view) else {
            return .failure(id: req.id, code: "dbg.frame_unavailable",
                            message: "view 还未渲染或 frame buffer 为空")
        }
        lastFrameSha256 = shot.sha256
        do {
            let items = try OCREngine.recognize(pngData: shot.data, region: nil)
            let needle = query.lowercased()
            let hit = items.first { $0.text.lowercased().contains(needle) }
            let payload: IPCDbgFindTextPayload
            if let it = hit {
                payload = IPCDbgFindTextPayload(
                    match: true,
                    x: it.x, y: it.y, width: it.width, height: it.height,
                    centerX: it.x + it.width / 2, centerY: it.y + it.height / 2,
                    text: it.text, confidence: it.confidence
                )
            } else {
                payload = IPCDbgFindTextPayload(match: false)
            }
            guard let json = try? String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "find_text payload 编码失败")
            }
            return .success(id: req.id, data: ["payload": json])
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
        }
    }

    // MARK: - 辅助

    /// guest framebuffer 分辨率 (与 ConfigBuilder 当前硬编码对齐).
    /// TODO: 将来 VMConfig 加 displaySpec 后, 这里改成读 config.
    private func guestFramebufferSize() -> (Int, Int) {
        switch guestOS {
        case .linux: return (1024, 768)
        case .macOS: return (1920, 1080)
        }
    }

    private func parsePoint(_ x: String?, _ y: String?) throws -> CGPoint {
        guard let xs = x, let ys = y, let xd = Double(xs), let yd = Double(ys) else {
            throw HVMError.config(.invalidEnum(field: "mouse.coords",
                                                raw: "\(x ?? "nil"),\(y ?? "nil")",
                                                allowed: ["数字 x,y"]))
        }
        return CGPoint(x: xd, y: yd)
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
