// GuestIcon.swift
// Guest OS 视觉标识. 专业工具风: 圆角方形 + SF Symbol + 单色 tint, 不再 ASCII 缩写.

import SwiftUI
import HVMBundle

public struct GuestStyle {
    public let label: String
    public let symbol: String     // SF Symbol name
    public let accent: Color

    public init(label: String, symbol: String, accent: Color) {
        self.label = label
        self.symbol = symbol
        self.accent = accent
    }
}

public enum GuestVisual {
    public static func style(for os: GuestOSType) -> GuestStyle {
        switch os {
        case .linux:
            return GuestStyle(label: "Linux", symbol: "terminal.fill",
                              accent: HVMColor.guestLinuxAccent)
        case .macOS:
            return GuestStyle(label: "macOS", symbol: "apple.logo",
                              accent: HVMColor.guestMacOSAccent)
        case .windows:
            return GuestStyle(label: "Windows", symbol: "macwindow",
                              accent: HVMColor.guestWindowsAccent)
        }
    }
}

/// Guest 标识方块. 卡片底 + accent tint icon + 圆角.
public struct GuestBadge: View {
    let os: GuestOSType
    let size: CGFloat

    public init(os: GuestOSType, size: CGFloat = 36) {
        self.os = os
        self.size = size
    }

    public var body: some View {
        let style = GuestVisual.style(for: os)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(style.accent.opacity(0.15))
            // size * 0.50 是动态尺寸 — 父 View 传入 size 决定字号, 不能 token 化.
            // 这是 token 体系约束的合规例外: 跟随父尺寸的图形渲染.
            Image(systemName: style.symbol)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(style.accent)
        }
        .frame(width: size, height: size)
    }
}
