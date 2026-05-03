// hvm-dbg/Support/OutputFormat.swift
// CLI 通用输出格式 (human / json). bail/bailJSON/printJSON 共用实现在 HVMUtils,
// 本文件保留 hvm-dbg 专属退出码映射 (含 dbg.* 系 20-23) + 调用 wrapper.

import ArgumentParser
import Foundation
import HVMCore
import HVMUtils

public enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case human
    case json
}

/// docs/DEBUG_PROBE.md 退出码: 与 hvm-cli 一致, + 20/21/22/23 给 hvm-dbg 专属.
public func exitCode(for code: String) -> Int32 {
    if code.hasPrefix("dbg.vm_not_running") { return 20 }
    if code.hasPrefix("ipc.socket_not_found") || code.hasPrefix("ipc.connection_refused") { return 21 }
    if code.hasPrefix("dbg.console_agent_offline") { return 22 }
    if code.hasPrefix("dbg.no_match") { return 23 }
    if code.hasPrefix("bundle.not_found") { return 3 }
    if code.hasPrefix("bundle.busy") { return 4 }
    if code.hasPrefix("ipc.timed_out") { return 6 }
    if code.hasPrefix("backend.") { return 10 }
    if code.hasPrefix("config.") { return 2 }
    return 1
}

/// human 模式渲染错误 + exit.
public func bail(_ error: Error) -> Never {
    HVMUtils.bail(error, exitCodeMap: exitCode(for:))
}

/// json 模式渲染错误 + exit.
public func bailJSON(_ error: Error) -> Never {
    HVMUtils.bailJSON(error, exitCodeMap: exitCode(for:))
}

/// pretty JSON 输出 (Encodable 版).
public func printJSON<T: Encodable>(_ value: T) {
    HVMUtils.printJSON(value)
}

/// pretty JSON 输出 (字典版); 部分 dbg 子命令直接拼 [String: Any].
public func printJSON(_ value: [String: Any]) {
    HVMUtils.printJSONDict(value)
}
