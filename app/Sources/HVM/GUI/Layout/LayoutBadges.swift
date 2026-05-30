// LayoutBadges.swift — sidebar + detail 共用的 VM 状态/OS 徽标映射. M4/M5.

#if NEW_GUI

import SwiftUI
import HVMControl
import HVMBundle

extension GuestOSType {
    /// guestOS 徽标文案
    var badgeLabel: String {
        switch self {
        case .macOS:   return "macOS"
        case .linux:   return "Linux"
        case .windows: return "Windows"
        }
    }

    /// guestOS 徽标配色 (macOS=青 accent / linux=蓝 info / windows=橙 warn, 与创建向导一致)
    var badgeVariant: HVMUI.Badge.Variant {
        switch self {
        case .macOS:   return .accent
        case .linux:   return .info
        case .windows: return .warn
        }
    }
}

extension RunState {
    var badgeLabel: String {
        switch self {
        case .running: return "运行中"
        case .stopped: return "已停止"
        }
    }

    var badgeVariant: HVMUI.Badge.Variant {
        switch self {
        case .running: return .success
        case .stopped: return .neutral
        }
    }
}

#endif
