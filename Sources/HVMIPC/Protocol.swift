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

    // hvm-dbg 子命令对应的 op (M5)
    case dbgScreenshot = "dbg.screenshot"
    case dbgStatus     = "dbg.status"
    case dbgKey        = "dbg.key"
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
