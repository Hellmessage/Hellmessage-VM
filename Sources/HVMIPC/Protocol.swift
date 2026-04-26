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
