// HVMIPC/Protocol.swift
// hvm-cli / hvm-dbg / HVMHost 共享的 JSON 协议定义.
//   M1: status / stop / kill
//   M5: dbg.screenshot / dbg.status (hvm-dbg 走的子集)
//
// 协议版本不做兼容协商, 全家桶同版本编译 (hvm-cli + hvm-dbg + HVM 都来自同一次 swift build).

import Foundation

public enum IPCProtocol {
    /// 协议版本, 不做兼容协商 (全家桶同版本编译)
    public static let version: Int = 1
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var op: String
    public var args: [String: String]

    public init(id: String = UUID().uuidString, op: String, args: [String: String] = [:]) {
        self.id = id
        self.op = op
        self.args = args
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
