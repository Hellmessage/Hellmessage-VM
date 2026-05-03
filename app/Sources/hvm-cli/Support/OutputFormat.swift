// hvm-cli/Support/OutputFormat.swift
// CLI 通用输出格式 (human / json). bail/bailJSON/printJSON 共用实现在 HVMUtils,
// 本文件保留 hvm-cli 专属的退出码映射 + 调用 wrapper.

import ArgumentParser
import Foundation
import HVMCore
import HVMUtils

public enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case human
    case json
}

/// docs/CLI.md 退出码映射 (hvm-cli 视角).
public func exitCode(for code: String) -> Int32 {
    if code.hasPrefix("bundle.not_found") { return 3 }
    if code.hasPrefix("bundle.busy") || code.hasPrefix("backend.disk_busy") { return 4 }
    if code.hasPrefix("backend.invalid_transition") { return 5 }
    if code.hasPrefix("ipc.timed_out") { return 6 }
    if code.hasPrefix("backend.") { return 10 }
    if code.hasPrefix("config.") { return 2 }
    return 1
}

/// human 模式渲染错误 + exit. 走 HVMUtils.bail 注入本地退出码映射.
public func bail(_ error: Error) -> Never {
    HVMUtils.bail(error, exitCodeMap: exitCode(for:))
}

/// json 模式渲染错误 + exit.
public func bailJSON(_ error: Error) -> Never {
    HVMUtils.bailJSON(error, exitCodeMap: exitCode(for:))
}

/// pretty JSON 输出 (Encodable 版); HVMUtils 直接复用.
public func printJSON<T: Encodable>(_ value: T) {
    HVMUtils.printJSON(value)
}
