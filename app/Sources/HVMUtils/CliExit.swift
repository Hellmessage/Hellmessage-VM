// HVMUtils/CliExit.swift
// 共用 CLI 退出 helper. hvm-cli / hvm-dbg 之前各有一份近 90% 重复的 OutputFormat.swift,
// 唯一差异是 exitCode(for:) 映射. 这里抽出共用 bail / bailJSON / printJSON, 各 CLI 通过
// exitCodeMap 闭包注入自己的退出码策略.

import Foundation
import HVMCore

/// 把任意 Error (优先识别 HVMError) 渲染为人类可读消息到 stderr 并 exit.
public func bail(_ error: Error, exitCodeMap: (String) -> Int32) -> Never {
    let uf = userFacing(of: error)
    var msg = "错误: \(uf.message)\n  code: \(uf.code)\n"
    for (k, v) in uf.details { msg += "  \(k): \(v)\n" }
    if let hint = uf.hint { msg += "  建议: \(hint)\n" }
    fputs(msg, stderr)
    exit(exitCodeMap(uf.code))
}

/// JSON 模式: 把 error 序列化为 JSON 到 stdout 并 exit.
public func bailJSON(_ error: Error, exitCodeMap: (String) -> Int32) -> Never {
    let uf = userFacing(of: error)
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
    exit(exitCodeMap(uf.code))
}

/// 把任意 Encodable 以 pretty JSON 输出到 stdout.
public func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

/// 字典版 (hvm-dbg 部分子命令需要直接拼 JSON 而非 Encodable model 时用).
public func printJSONDict(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

// MARK: - 内部

private func userFacing(of error: Error) -> UserFacingError {
    let hvmErr: HVMError
    if let e = error as? HVMError {
        hvmErr = e
    } else {
        hvmErr = .backend(.vzInternal(description: "\(error)"))
    }
    return hvmErr.userFacing
}
