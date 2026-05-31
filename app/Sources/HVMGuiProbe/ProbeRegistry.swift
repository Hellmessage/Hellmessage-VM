// HVMGuiProbe/ProbeRegistry.swift
// 自家 SwiftUI 控件 → 测试 closure 的全局注册表.
//
// 不用 NSAccessibility: SwiftUI 的 a11y tree 默认只在 VoiceOver 激活时暴露叶子控件
// (实测 macOS 14+), 程序内查询拿不到. 改走自家 closure registry: 控件 .hvmProbe(...)
// onAppear 注册 / onDisappear 移除, hvm-dbg gui click/type 直接调 closure, 不依赖系统 a11y.
// 局限: 不能模拟原生 mouse event 链 (hover 菜单等), 当前测试场景够用.

import AppKit
import Foundation
import HVMCore

/// 控件可执行的动作类型.
public enum ProbeAction: Sendable {
    /// 按钮: 点击 → 调 closure
    case button(@Sendable @MainActor () -> Void)
    /// 文本输入: setter (用于 type) + getter (用于 list 显示当前值)
    case textField(getter: @Sendable @MainActor () -> String,
                    setter: @Sendable @MainActor (String) -> Void)
    /// 开关: getter + setter
    case toggle(getter: @Sendable @MainActor () -> Bool,
                 setter: @Sendable @MainActor (Bool) -> Void)
}

/// 单条注册项.
public struct ProbeItem: Sendable {
    public let identifier: String
    /// 业务侧给的 label (例 "New VM" / "Cancel"). 给 list 显示用.
    public let label: String
    public let action: ProbeAction

    public var role: String {
        switch action {
        case .button: return "button"
        case .textField: return "textField"
        case .toggle: return "toggle"
        }
    }
}

/// 全局注册表 (主线程独占).
@MainActor
public enum ProbeRegistry {
    private static let log = HVMLog.logger("guiprobe.registry")
    nonisolated(unsafe) private static var items: [String: ProbeItem] = [:]

    public static func register(_ item: ProbeItem) {
        items[item.identifier] = item
    }

    public static func unregister(_ identifier: String) {
        items.removeValue(forKey: identifier)
    }

    public static func get(_ identifier: String) -> ProbeItem? {
        items[identifier]
    }

    public static func all() -> [ProbeItem] {
        Array(items.values).sorted { $0.identifier < $1.identifier }
    }

    public static func count() -> Int { items.count }
}
