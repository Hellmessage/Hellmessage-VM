// OutputFormat.swift
// CLI 通用输出格式 (human / json)

import ArgumentParser
import Foundation
import HVMCore

public enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case human
    case json
}

/// 把 HVMError 统一渲染到 stderr 并 exit
public func bail(_ error: Error) -> Never {
    let hvmErr: HVMError
    if let e = error as? HVMError {
        hvmErr = e
    } else {
        hvmErr = .backend(.vzInternal(description: "\(error)"))
    }
    let uf = hvmErr.userFacing

    // 默认走 human; 如果调用方设置 json 模式应主动渲染再 exit
    var msg = "错误: \(uf.message)\n  code: \(uf.code)\n"
    for (k, v) in uf.details {
        msg += "  \(k): \(v)\n"
    }
    if let hint = uf.hint {
        msg += "  建议: \(hint)\n"
    }
    fputs(msg, stderr)
    exit(exitCode(for: uf.code))
}

/// 按 docs/CLI.md 的退出码映射
public func exitCode(for code: String) -> Int32 {
    if code.hasPrefix("bundle.not_found") { return 3 }
    if code.hasPrefix("bundle.busy") || code.hasPrefix("backend.disk_busy") { return 4 }
    if code.hasPrefix("backend.invalid_transition") { return 5 }
    if code.hasPrefix("ipc.timed_out") { return 6 }
    if code.hasPrefix("backend.") { return 10 }
    if code.hasPrefix("config.") { return 2 }
    return 1
}

/// json 模式下打印错误再 exit
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

/// 把任意 Encodable 以 JSON 漂亮输出到 stdout
public func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
