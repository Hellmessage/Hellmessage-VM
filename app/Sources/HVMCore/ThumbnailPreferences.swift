// HVMCore/ThumbnailPreferences.swift
// 全局缩略图开关, 持久化到 com.hellmessage.vm UserDefaults, GUI / 子进程共享 (同 LoggingPreferences suite).
// 关闭时抓帧 timer short-circuit 不写 thumbnail.png + popover 返 nil, 已有 png 不删.
// 抓帧 timer 每 tick 重读 readEnabledFromDefaults() 即时生效, 不走 NotificationCenter.

import Foundation

/// 进程级单例, 控制 VM 列表 thumbnail 是否周期截图 + popover 是否展示.
/// @MainActor 仅约束写路径 (GUI toggle), 读路径 readEnabledFromDefaults
/// 是 nonisolated 静态方法, 任何线程能直接读.
public enum ThumbnailPreferences {

    private static let suiteName = "com.hellmessage.vm"
    private static let userDefaultsKey = "com.hellmessage.vm.thumbnail.enabled"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// 直接从 UserDefaults 读当前开关 — nonisolated, 任何线程 / 任何进程都能调.
    /// 默认 true (跟现状对齐, 旧用户感知不到行为变化).
    public static func readEnabledFromDefaults() -> Bool {
        let d = defaults
        if d.object(forKey: userDefaultsKey) == nil { return true }
        return d.bool(forKey: userDefaultsKey)
    }

    /// GUI toggle 入口: 写入 UserDefaults. 抓帧路径 / 读取路径每次 tick 都重新读,
    /// 不需要广播. 调用方一般在 GUI 主线程.
    @MainActor
    public static func setEnabled(_ value: Bool) {
        guard value != readEnabledFromDefaults() else { return }
        defaults.set(value, forKey: userDefaultsKey)
    }
}
