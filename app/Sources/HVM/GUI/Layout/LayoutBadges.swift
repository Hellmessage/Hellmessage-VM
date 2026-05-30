// LayoutBadges.swift — sidebar + detail 共用的 VM 状态/OS 徽标映射. M4/M5.


import SwiftUI
import HVMControl
import HVMBundle

extension GuestOSType {
    /// guestOS 徽标文案
    var badgeLabel: String {
        switch self {
        case .linux:   return "Linux"
        case .windows: return "Windows"
        }
    }

    /// guestOS 徽标配色 (linux=蓝 info / windows=橙 warn)
    var badgeVariant: HVMUI.Badge.Variant {
        switch self {
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

