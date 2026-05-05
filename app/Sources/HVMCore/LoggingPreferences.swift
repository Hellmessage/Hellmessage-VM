// HVMCore/LoggingPreferences.swift
// 全局日志输出开关. 持久化到 UserDefaults (com.hellmessage.vm.logging.enabled),
// 进程启动时读取, GUI / CLI / VMHost 共享同一份设置.
//
// 关闭时:
//   - LogSink 不再写 ~/Library/Application Support/HVM/logs/<date>.log
//   - os.Logger 调用仍走系统 unified logging (Console.app 仍能看, 但不落自家 .log)
//
// 不影响:
//   - 子进程自己 stderr → qemu-stderr.log / swtpm-stderr.log / host-<date>.log
//     这些是 Process stderr 重定向, 关本开关不会改子进程行为
//   - guest serial console-*.log 由 ConsoleBridge 写, 跟本开关无关
//
// 切换路径: GUI 状态栏 toggle → LoggingPreferences.shared.setEnabled(_:) → 同步刷
// LogSink + UserDefaults. 下次进程启动从 UserDefaults 读初值.

import Foundation

/// 进程级单例, 控制 LogSink 是否落自家 .log. @MainActor 仅约束写路径 (GUI toggle),
/// 读路径 readEnabledFromDefaults 是 nonisolated 静态方法, CLI / VMHost 任何线程能直接读.
public enum LoggingPreferences {

    private static let userDefaultsKey = "com.hellmessage.vm.logging.enabled"

    /// 直接从 UserDefaults 读当前开关 — nonisolated, 任何线程 / 任何进程都能调.
    /// 默认 true. CLI 短命进程 / actor / cooperative thread 都走这个.
    public static func readEnabledFromDefaults() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: userDefaultsKey) == nil { return true }
        return defaults.bool(forKey: userDefaultsKey)
    }

    /// GUI toggle 入口: 写入 UserDefaults + 异步通知 LogSink 切换 enabled.
    /// 调用方一般在 GUI 主线程.
    @MainActor
    public static func setEnabled(_ value: Bool) {
        guard value != readEnabledFromDefaults() else { return }
        UserDefaults.standard.set(value, forKey: userDefaultsKey)
        Task { await LogSink.shared.setEnabled(value) }
    }
}
