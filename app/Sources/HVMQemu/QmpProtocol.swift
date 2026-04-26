// HVMQemu/QmpProtocol.swift
// QMP (QEMU Machine Protocol) 类型与错误.
// 协议参考: https://wiki.qemu.org/Documentation/QMP
//
// 消息形态 (JSON over unix socket, 每条 \r\n 分隔):
//   greeting (server → client, on connect):
//     {"QMP": {"version": {...}, "capabilities": [...]}}
//   command (client → server):
//     {"execute": "<name>", "id": "<id>", "arguments": {...}}
//   response (server → client, 与 command id 配对):
//     {"return": <any>, "id": "<id>"}
//     {"error": {"class": "...", "desc": "..."}, "id": "<id>"}
//   event (server → client, 异步):
//     {"event": "<NAME>", "timestamp": {"seconds": ..., "microseconds": ...}, "data": {...}}

import Foundation

public enum QmpError: Error, Sendable, Equatable {
    /// 收到无法解析的 JSON 行
    case parseError(reason: String)
    /// 协议握手 / 状态机异常 (例如缺 greeting / 重复连接)
    case protocolError(reason: String)
    /// 底层 socket 失败 (open / connect / read / write)
    case socketError(reason: String, errno: Int32)
    /// QEMU 返回的命令错误 (response 里 "error" 字段)
    case qemu(class: String, desc: String)
    /// 客户端被 close, 但有未完成的命令
    case closed
    /// 操作超时
    case timeout
}

/// QMP 服务端推送的异步事件 (例 SHUTDOWN / RESET / STOP / RESUME / POWERDOWN)
public struct QmpEvent: Sendable, Equatable {
    public let name: String
    /// QEMU 的 monotonic timestamp (Double 秒, 含小数微秒)
    public let timestamp: Double
    /// 事件 data 字段的原始 JSON bytes (调用方按 event name 自己解码)
    public let dataJSON: Data

    public init(name: String, timestamp: Double, dataJSON: Data) {
        self.name = name
        self.timestamp = timestamp
        self.dataJSON = dataJSON
    }
}

/// query-status 的响应载荷.
/// QEMU 返回 {"return": {"status": "running", "running": true}} (10.x 起 singlestep 已移除)
public struct QmpStatus: Sendable, Codable, Equatable {
    /// 详细 vm 状态字符串. 常见: "running" / "paused" / "shutdown" / "internal-error" / ...
    public let status: String
    /// CPU 是否在执行
    public let running: Bool
    /// 是否单步调试模式 (QEMU 8.x 起从 vm 级别移到 vCPU 级别, 新版本不再返回此字段)
    public let singlestep: Bool?

    public init(status: String, running: Bool, singlestep: Bool? = nil) {
        self.status = status
        self.running = running
        self.singlestep = singlestep
    }
}
