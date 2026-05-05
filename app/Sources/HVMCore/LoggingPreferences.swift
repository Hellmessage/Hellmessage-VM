// HVMCore/LoggingPreferences.swift
// 全局日志输出开关. 持久化到 com.hellmessage.vm 的 UserDefaults
// (key: com.hellmessage.vm.logging.enabled), 进程启动时读取, GUI / CLI / VMHost 共享.
//
// 关闭时 (覆盖范围, 全部走 readEnabledFromDefaults() gate):
//   - LogSink 不再写 ~/Library/Application Support/HVM/logs/<date>.log
//   - 主 GUI / hvm-cli 派生 VMHost 子进程不再创建 host-<date>.log
//     (Process stdout/stderr 改重定向到 /dev/null, vmLogsDir 子目录也不创建)
//   - VMHost 子进程内 (QemuHostEntry / hvm-dbg qemu-launch) 不再创建
//     qemu-stderr.log / swtpm.log / swtpm-stderr.log
//   - os.Logger 调用仍走系统 unified logging (Console.app 仍能看, 但不落自家 .log)
//
// 不影响:
//   - guest 自己 serial console-*.log 由 ConsoleBridge / QemuConsoleBridge 写入
//     <bundle>/logs/, 是 guest 自身输出 (跟 host 侧诊断日志语义不同), 跟本开关无关
//
// 作用时机: LogSink 切换即时生效 (close fileHandle 不再写). 子进程 host log /
// qemu-stderr / swtpm.log 在 VM 启动时拍板; 运行中切换不影响已开 fd, 下次启 VM 才生效.
//
// 切换路径: GUI 状态栏 toggle → LoggingPreferences.shared.setEnabled(_:) → 同步刷
// LogSink + UserDefaults. 下次进程启动从 UserDefaults 读初值.
//
// 跨进程共享: 显式 UserDefaults(suiteName: "com.hellmessage.vm") 而不是 .standard.
// HVM.app 内 .standard 走 Bundle.main.bundleIdentifier 等于 com.hellmessage.vm OK,
// 但 hvm-cli 是无 bundle 的 CLI 二进制, .standard 会落到执行档名 (hvm-cli) 域,
// 看不到 GUI 写的开关. 改 suite 后 GUI / CLI / 子进程统一读同一份
// ~/Library/Preferences/com.hellmessage.vm.plist.

import Foundation

/// 进程级单例, 控制 host 侧日志是否落盘. @MainActor 仅约束写路径 (GUI toggle),
/// 读路径 readEnabledFromDefaults 是 nonisolated 静态方法, CLI / VMHost 任何线程能直接读.
public enum LoggingPreferences {

    private static let suiteName = "com.hellmessage.vm"
    private static let userDefaultsKey = "com.hellmessage.vm.logging.enabled"

    /// 显式 suiteName 共享 plist (GUI / CLI / 子进程统一); 拿不到 (理论上不会) 兜底 .standard.
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
