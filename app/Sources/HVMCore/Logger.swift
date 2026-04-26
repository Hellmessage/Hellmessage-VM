// HVMCore/Logger.swift
// 薄封装 os.Logger, 统一 subsystem 与 category 命名.
// 敏感字段脱敏约束见 docs/ERROR_MODEL.md.
//
// 副作用: 第一次调 HVMLog.logger() 会 lazy 启动 LogSink, 把本进程发的 log 异步 mirror
// 到 ~/Library/Application Support/HVM/logs/<yyyy-MM-dd>.log, 按天 rotate, 保留 14 天.
// 短命 CLI (hvm-cli/hvm-dbg) 跑完即退, OSLogStore poll 没机会启动也无所谓; 长命 GUI/VMHost
// 能持续落盘.

import Foundation
import os

/// HVM 的日志门面, 统一挂在 subsystem `com.hellmessage.vm` 下
public enum HVMLog {
    public static let subsystem = "com.hellmessage.vm"

    /// 各模块以 category 区分日志来源.
    /// 第一次调用会触发 LogSink.shared.start() (幂等), 启用文件 mirror.
    public static func logger(_ category: String) -> Logger {
        // LogSink 是 @MainActor, 我们不能在任意线程同步调 start;
        // 但 LogSink.shared.start() 内部都是轻量赋值 + Task.detached, 跨 actor 触发即可.
        Task { @MainActor in
            LogSink.shared.start()
        }
        return Logger(subsystem: subsystem, category: category)
    }
}
