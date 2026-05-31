// HVMCore/LoggingPreferences.swift
// 全局日志输出开关, 持久化到 com.hellmessage.vm UserDefaults, GUI / CLI / VMHost 共享.
// 关闭时 host 侧 .log (顶层 date.log / host-*.log / qemu-stderr.log / swtpm.log) 全不落盘,
// 仅 os.Logger 走系统 unified logging; guest 自己的 console-*.log 不受影响.
// LogSink 切换即时生效; 子进程的 host/qemu/swtpm log 在 VM 启动时拍板, 运行中切换下次启 VM 才生效.

import Foundation

/// 进程级单例, 控制 host 侧日志是否落盘. @MainActor 仅约束写路径 (GUI toggle),
/// 读路径 readEnabledFromDefaults 是 nonisolated 静态方法, CLI / VMHost 任何线程能直接读.
public enum LoggingPreferences {

    private static let suiteName = "com.hellmessage.vm"
    private static let userDefaultsKey = "com.hellmessage.vm.logging.enabled"

    /// 必须显式 suiteName 共享 plist: 无 bundle 的 hvm-cli 用 .standard 会落到执行档名域, 看不到 GUI 写的开关
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 直接从 UserDefaults 读当前开关 — nonisolated, 任何线程 / 任何进程都能调.
    /// 默认 true. CLI 短命进程 / actor / cooperative thread 都走这个.
    public static func readEnabledFromDefaults() -> Bool {
        let d = defaults
        if d.object(forKey: userDefaultsKey) == nil { return true }
        return d.bool(forKey: userDefaultsKey)
    }

    /// GUI toggle 入口: 写入 UserDefaults + 异步通知 LogSink 切换 enabled.
    /// 调用方一般在 GUI 主线程.
    @MainActor
    public static func setEnabled(_ value: Bool) {
        guard value != readEnabledFromDefaults() else { return }
        defaults.set(value, forKey: userDefaultsKey)
        Task { await LogSink.shared.setEnabled(value) }
    }
}
