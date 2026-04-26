// GuestIcon.swift
// 单色 terminal 风 guest 标识. 不再用彩色渐变, 与 hacker 主题统一

import SwiftUI
import HVMBundle

public struct GuestStyle {
    public let label: String
    public let shortSymbol: String    // ASCII 单字符缩写, 如 "λ" "⌘"
    public let accent: Color

    public init(label: String, shortSymbol: String, accent: Color) {
        self.label = label
        self.shortSymbol = shortSymbol
        self.accent = accent
    }
}

public enum GuestVisual {
    public static func style(for os: GuestOSType) -> GuestStyle {
        switch os {
        case .linux:
            return GuestStyle(label: "linux",
                              shortSymbol: ">_",
                              accent: HVMColor.accent)
        case .macOS:
            return GuestStyle(label: "macOS",
                              shortSymbol: "⌘",
                              accent: Color(red: 0.85, green: 0.90, blue: 1.00))
        }
    }
}

/// 方形 badge, 单色边框 + 中心 ASCII 缩写. 取代之前的彩色渐变 emoji badge.
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
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(HVMColor.bgCard)
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .stroke(style.accent.opacity(0.6), lineWidth: 1)
            Text(style.shortSymbol)
                .font(.system(size: size * 0.38, weight: .bold, design: .monospaced))
                .foregroundStyle(style.accent)
        }
        .frame(width: size, height: size)
    }
}
