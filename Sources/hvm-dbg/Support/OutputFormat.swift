// hvm-dbg/Support/OutputFormat.swift
// CLI 通用输出格式 (与 hvm-cli/Support/OutputFormat.swift 一致, 重复一份给独立 target 用)
// hvm-dbg 默认 json (主要给自动化使用), 而 hvm-cli 默认 human

import ArgumentParser
import Foundation
import HVMCore

public enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case human
    case json
}

public func bail(_ error: Error) -> Never {
    let hvmErr: HVMError
    if let e = error as? HVMError {
        hvmErr = e
    } else {
        hvmErr = .backend(.vzInternal(description: "\(error)"))
    }
    let uf = hvmErr.userFacing
    var msg = "错误: \(uf.message)\n  code: \(uf.code)\n"
    for (k, v) in uf.details { msg += "  \(k): \(v)\n" }
    if let hint = uf.hint { msg += "  建议: \(hint)\n" }
    fputs(msg, stderr)
    exit(exitCode(for: uf.code))
}

/// docs/DEBUG_PROBE.md 退出码: 与 hvm-cli 一致, + 20/21/22/23 给 hvm-dbg 专属
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

public func bailJSON(_ error: Error) -> Never {
    let hvmErr: HVMError
    if let e = error as? HVMError {
        hvmErr = e
    } else {
        hvmErr = .backend(.vzInternal(description: "\(error)"))
    }
    let uf = hvmErr.userFacing
    let payload: [String: Any] = [
        "error": [
            "code": uf.code,
            "message": uf.message,
            "details": uf.details,
            "hint": uf.hint as Any,
        ] as [String: Any],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(exitCode(for: uf.code))
}

public func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

public func printJSON(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
