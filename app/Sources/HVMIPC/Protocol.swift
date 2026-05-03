// HVMIPC/Protocol.swift
// hvm-cli / hvm-dbg / HVMHost 共享的 JSON 协议定义.
//   M1: status / stop / kill
//   M5: dbg.screenshot / dbg.status (hvm-dbg 走的子集)
//
// === 协议版本 ===
//
// 期望全家桶同版本编译 (hvm-cli + hvm-dbg + HVM 来自同一次 swift build), 但用户可能从老
// .app 启动 VMHost, 又用新装好的 hvm-cli 调用 — 此时版本错位会让请求语义模糊.
//
// 协议:
//   - 客户端 (SocketClient) 自动在 IPCRequest 里填 protoVersion = IPCProtocol.version
//   - 服务端 (SocketServer 调 handler) 在 dispatcher 之前校验 protoVersion:
//     - nil (老客户端发的请求, 没有这个字段) → 视作 legacy, 接受 (向后兼容)
//     - != current → 返 ipc.protocol_mismatch 错误, 让客户端清晰报错
//   - 未知 op 由 handler 兜底 (HVMHostEntry.handle default 分支), 返 ipc.unknown_op
//
// JSONDecoder 默认忽略未知字段, 所以 "新客户端 → 老服务端" 不会因为 protoVersion 字段失败.
// "老客户端 → 新服务端" 因为 nil 走 legacy 分支也接受. 真正错位需双方都 != current 才会拦下.

import Foundation

public enum IPCProtocol {
    /// 协议版本. 改 IPCRequest / IPCResponse / 已知 op 语义时 +1.
    /// 加新 op (向上扩展) 不需要 +1.
    public static let version: Int = 1
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var op: String
    public var args: [String: String]
    /// 客户端协议版本. nil 视作 legacy 客户端 (兼容老 hvm-cli).
    public var protoVersion: Int?

    public init(
        id: String = UUID().uuidString,
        op: String,
        args: [String: String] = [:],
        protoVersion: Int? = IPCProtocol.version
    ) {
        self.id = id
        self.op = op
        self.args = args
        self.protoVersion = protoVersion
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var data: [String: String]?
    public var error: IPCErrorPayload?

    public static func success(id: String, data: [String: String] = [:]) -> IPCResponse {
        IPCResponse(id: id, ok: true, data: data, error: nil)
    }

    public static func failure(id: String, code: String, message: String, details: [String: String] = [:]) -> IPCResponse {
        IPCResponse(id: id, ok: false, data: nil,
                    error: IPCErrorPayload(code: code, message: message, details: details))
    }

    /// 把 Codable payload 编码为 JSON, 包成 success 响应; 编码失败返 failure(ipc.encode_failed).
    /// 替代调用方 14 处重复的 `try? JSONEncoder().encode + guard + .success/.failure` 模式.
    /// kind: 用于失败 message, 例 "screenshot" / "ocr" / "find_text" 让客户端定位是哪类响应失败.
    /// dateStrategy: 默认 .iso8601 (与 hvm-cli status 等业务约定一致); 调用方需要别的可显式传.
    public static func encoded<T: Encodable>(
        id: String,
        payload: T,
        kind: String,
        dateStrategy: JSONEncoder.DateEncodingStrategy = .iso8601
    ) -> IPCResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateStrategy
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(id: id, code: "ipc.encode_failed",
                            message: "\(kind) payload 编码失败")
        }
        return .success(id: id, data: ["payload": json])
    }
}

public struct IPCErrorPayload: Codable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: String]
}

// MARK: - 已知 op

public enum IPCOp: String, Sendable {
    case status  = "status"
    case stop    = "stop"
    case kill    = "kill"
    case pause   = "pause"
    case resume  = "resume"

    // hvm-dbg 子命令对应的 op (M5)
    case dbgScreenshot   = "dbg.screenshot"
    case dbgStatus       = "dbg.status"
    case dbgKey          = "dbg.key"
    case dbgMouse        = "dbg.mouse"
    case dbgOcr          = "dbg.ocr"
    case dbgFindText     = "dbg.find_text"
    case dbgBootProgress = "dbg.boot_progress"
    case dbgConsoleRead  = "dbg.console.read"
    case dbgConsoleWrite = "dbg.console.write"
    /// hvm-dbg display-info — 通过 QMP screendump 拿 guest 真实当前 framebuffer 尺寸
    /// (PPM header). 用于验证 spice-vdagent dynamic resize 是否真生效 (resize 触发前后
    /// 两次 display-info 对比 widthPx/heightPx 是否变化).
    case dbgDisplayInfo  = "dbg.display.info"
    /// hvm-dbg display-resize — 模拟 GUI 拖窗口触发 host → guest resize. 在 host 进程
    /// 内 spawn 临时 DisplayChannel + VdagentClient, 走两条通路:
    ///   A. HDP RESIZE_REQUEST (适用 Linux virtio-gpu, ramfb 不消费)
    ///   B. vdagent MONITORS_CONFIG (适用 Win spice-vdagent → SetDisplayConfig)
    /// 测试规约: 调用此 op 时 GUI **不能**同时 attach (iosurface/vdagent chardev 单 client).
    case dbgDisplayResize = "dbg.display.resize"
    /// 通过 qemu-guest-agent (qga) 在 guest 内跑 process, 拿 stdout/stderr/exit_code.
    /// 给 hvm-dbg exec-guest 用. 配套 guest 内 qemu-ga.exe 服务 + argv 挂的
    /// virtio-serial port org.qemu.guest_agent.0 (chardev qga). 不依赖 keyboard typing
    /// (避 IME 字符替换) / OCR (避识别误差) / GUI mouse (避 USB tablet 坐标问题).
    case dbgExecGuest    = "dbg.exec.guest"
    /// host (GUI) 通知 VMHost 改 guest 显示分辨率, args.width/height. VMHost 持有
    /// 持久 vdagent socket, 通过 vdagent VDAgentMonitorsConfig 转给 guest spice-vdagent.
    /// 取代老的"GUI 直连 vdagent socket"路径 — vdagent socket 是 single-client,
    /// 必须由 VMHost 唯一持有 (PasteboardBridge 也用同一 socket).
    case displaySetMonitors = "display.setMonitors"
    /// host (GUI) 通知 VMHost 切换剪贴板共享 enabled, args.enabled = "1" / "0".
    /// 立即生效 (不必重启 VM). 持久化由 GUI 侧负责 (改 yaml).
    case clipboardSetEnabled = "clipboard.setEnabled"
}

/// dbg.display.info payload — guest 真实当前 framebuffer 尺寸.
public struct IPCDbgDisplayInfoPayload: Codable, Sendable {
    public let widthPx: Int
    public let heightPx: Int
    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// dbg.display.resize 响应 — 双通路 send 结果, 任一通路结果由日志为准, 这里只摘要.
public struct IPCDbgDisplayResizePayload: Codable, Sendable {
    public let widthPx: UInt32
    public let heightPx: UInt32
    public let hdpResult: String   // "sent" / "skipped" / "connect_failed: ..."
    public let vdagentResult: String  // "sent" / "connect_failed: ..." / "skipped"
    public init(widthPx: UInt32, heightPx: UInt32, hdpResult: String, vdagentResult: String) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.hdpResult = hdpResult
        self.vdagentResult = vdagentResult
    }
}

/// dbg.exec.guest payload — 跑 guest 内 process 拿结果. exit_code=-1 表示 timeout.
public struct IPCDbgExecPayload: Codable, Sendable {
    public let exitCode: Int
    public let stdoutBase64: String
    public let stderrBase64: String
    public init(exitCode: Int, stdoutBase64: String, stderrBase64: String) {
        self.exitCode = exitCode
        self.stdoutBase64 = stdoutBase64
        self.stderrBase64 = stderrBase64
    }
}

// MARK: - Status payload (JSON-stringified for `data` values)

// MARK: - hvm-dbg payloads (M5)

/// dbg.screenshot 响应. PNG 二进制 base64 编码 (Unix socket 单帧最大 4GB, 1080p PNG 约 0.2-0.5MB,
/// base64 后约 0.7MB, 完全够用)
public struct IPCDbgScreenshotPayload: Codable, Sendable {
    public var pngBase64: String
    public var widthPx: Int
    public var heightPx: Int
    public var sha256: String

    public init(pngBase64: String, widthPx: Int, heightPx: Int, sha256: String) {
        self.pngBase64 = pngBase64
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.sha256 = sha256
    }
}

/// dbg.ocr 响应. texts 数组里每项 bbox 是 guest 像素左上原点.
public struct IPCDbgOcrPayload: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var text: String
        public var confidence: Float

        public init(x: Int, y: Int, width: Int, height: Int, text: String, confidence: Float) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.text = text; self.confidence = confidence
        }
    }
    public var widthPx: Int
    public var heightPx: Int
    public var texts: [Item]

    public init(widthPx: Int, heightPx: Int, texts: [Item]) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.texts = texts
    }
}

/// dbg.find_text 响应. 找到 (match=true) 返回 bbox + center; 找不到 (match=false) 其余字段 nil.
public struct IPCDbgFindTextPayload: Codable, Sendable {
    public var match: Bool
    public var x: Int?
    public var y: Int?
    public var width: Int?
    public var height: Int?
    public var centerX: Int?
    public var centerY: Int?
    public var text: String?
    public var confidence: Float?

    public init(match: Bool, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil,
                centerX: Int? = nil, centerY: Int? = nil, text: String? = nil, confidence: Float? = nil) {
        self.match = match
        self.x = x; self.y = y; self.width = width; self.height = height
        self.centerX = centerX; self.centerY = centerY
        self.text = text; self.confidence = confidence
    }
}

/// dbg.status 响应. 偏 guest 视角 (区别于 hvm-cli status 的 host 视角).
/// 给 AI agent 判断 "画面变化没" / "VM 还活着没"
public struct IPCDbgStatusPayload: Codable, Sendable {
    public var state: String                     // RunState string
    public var guestWidthPx: Int                 // guest framebuffer 宽
    public var guestHeightPx: Int                // guest framebuffer 高
    public var lastFrameSha256: String?          // 最近一次截图 hash, 没截过 = nil
    public var consoleAgentOnline: Bool          // M5 phase 5 console 通道接入后 = true

    public init(state: String, guestWidthPx: Int, guestHeightPx: Int,
                lastFrameSha256: String?, consoleAgentOnline: Bool) {
        self.state = state
        self.guestWidthPx = guestWidthPx
        self.guestHeightPx = guestHeightPx
        self.lastFrameSha256 = lastFrameSha256
        self.consoleAgentOnline = consoleAgentOnline
    }
}

/// dbg.console.read 响应. data 是 base64 编码的原始字节 (guest stdout 可能是 UTF-8 也可能是
/// 二进制 escape 序列, 不强行解码). 客户端拿 totalBytes 当下次 sinceBytes 实现增量轮询.
public struct IPCDbgConsoleReadPayload: Codable, Sendable {
    public var dataBase64: String         // 本次返回的字节
    public var totalBytes: Int            // guest 累计输出字节数 (跨 ring 截断仍累加)
    public var returnedSinceBytes: Int    // 本次数据起点; 落在 ring 窗口外时会上调到窗口左界

    public init(dataBase64: String, totalBytes: Int, returnedSinceBytes: Int) {
        self.dataBase64 = dataBase64
        self.totalBytes = totalBytes
        self.returnedSinceBytes = returnedSinceBytes
    }
}

/// dbg.boot_progress 响应. 启发式判断 guest 启动阶段, confidence < 0.5 时 phase=unknown.
/// 阶段定义见 docs/DEBUG_PROBE.md 的 boot-progress 章节.
public struct IPCDbgBootProgressPayload: Codable, Sendable {
    public var phase: String          // bios | boot-logo | ready-tty | ready-gui | unknown
    public var confidence: Float      // [0, 1]
    public var elapsedSec: Int?       // 自 startedAt 起的秒数, 没启动过 = nil

    public init(phase: String, confidence: Float, elapsedSec: Int?) {
        self.phase = phase
        self.confidence = confidence
        self.elapsedSec = elapsedSec
    }
}

public struct IPCStatusPayload: Codable, Sendable {
    public var state: String        // RunState 的 string
    public var id: String           // UUID string
    public var bundlePath: String
    public var displayName: String
    public var guestOS: String
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var pid: Int32
    public var startedAt: Date?

    public init(state: String, id: String, bundlePath: String, displayName: String,
                guestOS: String, cpuCount: Int, memoryMiB: UInt64, pid: Int32, startedAt: Date?) {
        self.state = state
        self.id = id
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.pid = pid
        self.startedAt = startedAt
    }
}
