// HVMCore/Logger.swift
// 薄封装 os.Logger, 统一 subsystem 与 category 命名
// 敏感字段脱敏约束见 docs/ERROR_MODEL.md

import Foundation
import os

/// HVM 的日志门面, 统一挂在 subsystem `com.hellmessage.vm` 下
public enum HVMLog {
    public static let subsystem = "com.hellmessage.vm"

    /// 各模块以 category 区分日志来源
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
