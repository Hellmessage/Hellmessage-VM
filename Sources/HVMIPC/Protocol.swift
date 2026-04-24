// HVMIPC/Protocol.swift
// hvm-cli / hvm-dbg / HVMHost 共享的 JSON 协议定义
// M1 支持 op: status / stop

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
}

// MARK: - Status payload (JSON-stringified for `data` values)

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
