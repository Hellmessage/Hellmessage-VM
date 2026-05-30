// HVMCore/Logger.swift
// 薄封装 os.Logger, 统一 subsystem 与 category 命名.
// 第一次调 HVMLog.logger() lazy 启动 LogSink 落盘日志 (见 LogSink.swift).

import Foundation
import os

/// HVM 的日志门面, 统一挂在 subsystem `com.hellmessage.vm` 下
public enum HVMLog {
    public static let subsystem = "com.hellmessage.vm"

    /// 各模块以 category 区分日志来源. 第一次调用触发 LogSink.shared.start() (幂等).
    public static func logger(_ category: String) -> Logger {
        // initialEnabled 走 nonisolated 静态读, 不直接碰 @MainActor 的 LoggingPreferences
        let initialEnabled = LoggingPreferences.readEnabledFromDefaults()
        Task {
            await LogSink.shared.start(initialEnabled: initialEnabled)
        }
        return Logger(subsystem: subsystem, category: category)
    }
}
