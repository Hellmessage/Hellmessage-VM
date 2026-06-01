// LayoutBadges.swift — sidebar + detail 共用的 VM 状态/OS 徽标映射.


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

extension NetworkMode {
    /// 网络模式徽标文案 (NAT / 桥接 / Host / 共享)
    var badgeLabel: String {
        switch self {
        case .user:         return "NAT"
        case .vmnetShared:  return "共享"
        case .vmnetHost:    return "Host"
        case .vmnetBridged: return "桥接"
        case .none:         return "无网络"
        }
    }

    /// 网络模式徽标配色 (桥接=真二层走 accent 强调, NAT/共享/host 走 info, 无网络 neutral)
    var badgeVariant: HVMUI.Badge.Variant {
        switch self {
        case .vmnetBridged: return .accent
        case .none:         return .neutral
        default:            return .info
        }
    }

    /// 网络模式徽标图标 (SF Symbol)
    var badgeIcon: String {
        switch self {
        case .user:         return "network"
        case .vmnetShared:  return "person.2.fill"
        case .vmnetHost:    return "desktopcomputer"
        case .vmnetBridged: return "point.3.connected.trianglepath.dotted"
        case .none:         return "network.slash"
        }
    }
}

