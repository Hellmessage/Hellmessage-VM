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
    private let startedAtProvider: () -> Date?
    private let consoleBridgeProvider: () -> ConsoleBridge?
    private var lastFrameSha256: String? = nil

    public init(view: HVMView, guestOS: GuestOSType,
                stateProvider: @escaping () -> RunState,
                startedAtProvider: @escaping () -> Date? = { nil },
                consoleBridgeProvider: @escaping () -> ConsoleBridge? = { nil }) {
        self.view = view
        self.guestOS = guestOS
        self.stateProvider = stateProvider
        self.startedAtProvider = startedAtProvider
        self.consoleBridgeProvider = consoleBridgeProvider
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
        case IPCOp.dbgBootProgress.rawValue: return handleBootProgress(req)
        case IPCOp.dbgConsoleRead.rawValue:  return handleConsoleRead(req)
        case IPCOp.dbgConsoleWrite.rawValue: return handleConsoleWrite(req)
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
        return .encoded(id: req.id, payload: payload, kind: "screenshot")
    }

    private func handleStatus(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        let (w, h) = guestFramebufferSize()
        let payload = IPCDbgStatusPayload(
            state: stateString(s),
            guestWidthPx: w,
            guestHeightPx: h,
            lastFrameSha256: lastFrameSha256,
            consoleAgentOnline: consoleBridgeProvider() != nil
        )
        return .encoded(id: req.id, payload: payload, kind: "dbg status")
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
            return .encoded(id: req.id, payload: payload, kind: "ocr")
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
            let payload: IPCDbgFindTextPayload
            if let hit = OCRTextSearch.find(in: items, query: query) {
                let it = hit.item
                payload = IPCDbgFindTextPayload(
                    match: true,
                    x: it.x, y: it.y, width: it.width, height: it.height,
                    centerX: it.x + it.width / 2, centerY: it.y + it.height / 2,
                    text: it.text, confidence: it.confidence
                )
            } else {
                payload = IPCDbgFindTextPayload(match: false)
            }
            return .encoded(id: req.id, payload: payload, kind: "find_text")
        } catch let e as HVMError {
            let uf = e.userFacing
            return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
        } catch {
            return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
        }
    }

    /// boot-progress: 启发式判断 guest 启动阶段, 给 AI agent 做粗分支决策用.
    /// 实现走 state + 截图 hash + OCR 关键词命中 三层启发, 不打开新通道.
    /// 启发式分级见 docs/DEBUG_PROBE.md boot-progress 章节.
    private func handleBootProgress(_ req: IPCRequest) -> IPCResponse {
        let s = stateProvider()
        let elapsed: Int? = startedAtProvider().map { Int(Date().timeIntervalSince($0)) }

        func reply(_ phase: String, _ confidence: Float) -> IPCResponse {
            let payload = IPCDbgBootProgressPayload(phase: phase, confidence: confidence, elapsedSec: elapsed)
            return .encoded(id: req.id, payload: payload, kind: "boot_progress")
        }

        // 非 running: 直接 bios (含 starting / paused / stopped / error / stopping)
        guard s == .running else { return reply("bios", 1.0) }

        // running 但抓不到帧: 还在 BIOS / EFI 阶段 (Metal drawable 还没首帧)
        guard let shot = ScreenCapture.capturePNG(from: view) else {
            return reply("bios", 0.7)
        }
        lastFrameSha256 = shot.sha256

        // 有帧, 跑 OCR 看屏幕上有没有可识别文字
        let items: [OCREngine.TextItem]
        do { items = try OCREngine.recognize(pngData: shot.data, region: nil) }
        catch { return reply("boot-logo", 0.5) }

        let cls = BootPhaseClassifier.classify(items: items, guestOS: guestOS)
        return reply(cls.phase, cls.confidence)
    }

    /// console.read: 增量拉 guest stdout. args: sinceBytes (默认 0).
    private func handleConsoleRead(_ req: IPCRequest) -> IPCResponse {
        guard let bridge = consoleBridgeProvider() else {
            return .failure(id: req.id, code: "dbg.console_unavailable",
                            message: "console bridge 未就绪 (VM 未启动?)")
        }
        let since = Int(req.args["sinceBytes"] ?? "0") ?? 0
        let r = bridge.read(sinceBytes: since)
        let payload = IPCDbgConsoleReadPayload(
            dataBase64: r.data.base64EncodedString(),
            totalBytes: r.totalBytes,
            returnedSinceBytes: r.returnedSinceBytes
        )
        return .encoded(id: req.id, payload: payload, kind: "console.read")
    }

    /// console.write: 写一段字节到 guest stdin. args: dataBase64 (优先) 或 text (UTF-8).
    private func handleConsoleWrite(_ req: IPCRequest) -> IPCResponse {
        guard let bridge = consoleBridgeProvider() else {
            return .failure(id: req.id, code: "dbg.console_unavailable",
                            message: "console bridge 未就绪 (VM 未启动?)")
        }
        let bytes: Data
        if let b64 = req.args["dataBase64"], let d = Data(base64Encoded: b64) {
            bytes = d
        } else if let text = req.args["text"] {
            bytes = Data(text.utf8)
        } else {
            return .failure(id: req.id, code: "config.missing_field",
                            message: "需要 args.dataBase64 或 args.text")
        }
        do {
            try bridge.write(bytes)
            return .success(id: req.id, data: ["bytesWritten": String(bytes.count)])
        } catch {
            return .failure(id: req.id, code: "dbg.console_write_failed", message: "\(error)")
        }
    }

    // MARK: - 辅助

    /// guest framebuffer 分辨率 (与 ConfigBuilder 当前硬编码对齐).
    /// TODO: 将来 VMConfig 加 displaySpec 后, 这里改成读 config.
    private func guestFramebufferSize() -> (Int, Int) {
        let s = guestOS.defaultFramebufferSize
        return (s.width, s.height)
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
