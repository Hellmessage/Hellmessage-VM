// HVMGuiProbe/ProbeRegistry.swift
// 自家 SwiftUI 控件 → 测试 closure 的全局注册表.
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md D-G2 (重构版).
//
// 为什么不用 NSAccessibility:
//   SwiftUI 通过 NSHostingView 合成 a11y children, 但默认只在 VoiceOver 激活时
//   暴露完整 tree. 程序内查询 accessibilityChildren() 拿不到 Button / TextField 等
//   叶子控件 (实测 macOS 14+). 强行用 AXUIElement 系列 C API 需要 a11y trust.
//
// 改走自家 closure registry 更直接:
//   - 控件 .hvmProbe(id: "dialog.X.button.Y", action: .button { ... }) 在 onAppear
//     注册到全局 dict, onDisappear 移除
//   - hvm-dbg gui click <id> 直接调 closure (= 等价用户点击触发的 action)
//   - hvm-dbg gui type <id> --text "..." 调 setter
//   - 不依赖系统 a11y 服务, 跨 SwiftUI / AppKit 一致
//
// 缺点: 不能模拟原生 mouse event 链 (例如 hover 后才出现的菜单). 当前 PR-11 测试场景
// 都是直接 button.action / textField.text, 这套足够. 后续如有 hover/drag 需求, 再加
// SimulatedNSEvent 路径.

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
