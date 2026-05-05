// HVMCore/ThumbnailPreferences.swift
// 全局缩略图开关. 持久化到 com.hellmessage.vm 的 UserDefaults
// (key: com.hellmessage.vm.thumbnail.enabled), 进程启动时读取, GUI / 子进程共享.
//
// 关闭时:
//   - VZ / QEMU 路径的 thumbnail 抓帧定时器内部 short-circuit, 不调
//     ThumbnailGenerator.capture / ThumbnailWriter.writeAtomic, 不写
//     <bundle>/meta/thumbnail.png
//   - 状态栏 popover (HVMApp.thumbnailForVM) 直接返 nil, 显示占位图标
//   - 已有的 thumbnail.png 不主动删除 (用户克隆 / 备份场景仍可能依赖), 仅停止刷新
//
// 不影响:
//   - 其他截图通路 (hvm-dbg screenshot 调试命令 / 用户主动截图)
//
// 切换路径: GUI 状态栏 toggle → ThumbnailPreferences.shared.setEnabled(_:) →
// 同步刷 UserDefaults. 抓帧 timer 每个 tick 重新读 readEnabledFromDefaults(),
// 即时生效 — 不需要 NotificationCenter 广播给运行中的 session.
//
// 跨进程共享: 显式 UserDefaults(suiteName: "com.hellmessage.vm"), 与
// LoggingPreferences 同一 suite, 走 ~/Library/Preferences/com.hellmessage.vm.plist.

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
