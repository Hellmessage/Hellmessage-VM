// Theme.swift
// Terminal / Hacker 风格统一 token.
// 纯黑三层底 + 青绿单色 accent + SF Mono 主导 + 1px 细边

import SwiftUI

public enum HVMColor {
    // 背景: 纯黑三层 (从外到内)
    public static let bgBase       = Color(red: 0.000, green: 0.000, blue: 0.000)     // #000
    public static let bgSidebar    = Color(red: 0.027, green: 0.027, blue: 0.031)     // #070708
    public static let bgCard       = Color(red: 0.043, green: 0.047, blue: 0.055)     // #0B0C0E
    public static let bgCardHi     = Color(red: 0.063, green: 0.067, blue: 0.078)
    public static let bgElevated   = Color(red: 0.082, green: 0.086, blue: 0.098)
    public static let bgHover      = Color.white.opacity(0.04)
    public static let bgSelected   = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.10)

    public static let border       = Color.white.opacity(0.08)
    public static let borderStrong = Color.white.opacity(0.16)
    public static let borderAccent = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.55)

    public static let textPrimary   = Color(red: 0.92, green: 0.93, blue: 0.94)
    public static let textSecondary = Color(red: 0.54, green: 0.56, blue: 0.60)
    public static let textTertiary  = Color(red: 0.32, green: 0.34, blue: 0.38)
    public static let textOnAccent  = Color.black

    // 单色 accent: 青绿 #00E5CC, hacker / terminal 感
    public static let accent       = Color(red: 0.000, green: 0.898, blue: 0.800)
    public static let accentHover  = Color(red: 0.180, green: 0.960, blue: 0.870)
    public static let accentMuted  = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.15)

    public static let statusRunning = Color(red: 0.22, green: 0.94, blue: 0.56)     // #39F08E
    public static let statusStopped = Color(red: 0.40, green: 0.43, blue: 0.47)
    public static let statusPaused  = Color(red: 1.00, green: 0.78, blue: 0.20)
    public static let statusError   = Color(red: 1.00, green: 0.33, blue: 0.33)

    public static let danger       = Color(red: 1.00, green: 0.33, blue: 0.33)

    // 系列 accent (用于 stat icon tint, 全部冷色避免破坏 hacker 风)
    public static let statCPU     = Color(red: 0.00, green: 0.90, blue: 0.80)      // 青绿
    public static let statMemory  = Color(red: 0.70, green: 0.80, blue: 1.00)      // 冷蓝
    public static let statDisk    = Color(red: 1.00, green: 0.78, blue: 0.20)      // 琥珀
    public static let statNetwork = Color(red: 0.35, green: 0.90, blue: 0.55)      // 绿
}

public enum HVMSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum HVMRadius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 10
    public static let pill: CGFloat = 999
}

public enum HVMBar {
    public static let toolbarHeight: CGFloat  = 42
    public static let statusBarHeight: CGFloat = 26
}

public enum HVMFont {
    // proportional (标题 / 名字 / 大数字)
    public static let hero    = Font.system(size: 22, weight: .semibold)
    public static let title   = Font.system(size: 16, weight: .semibold)
    public static let heading = Font.system(size: 13, weight: .semibold)

    // mono (正文 / 详情 / 状态 / label)
    public static let body       = Font.system(size: 12, design: .monospaced)
    public static let bodyBold   = Font.system(size: 12, weight: .semibold, design: .monospaced)
    public static let caption    = Font.system(size: 11, design: .monospaced)
    public static let small      = Font.system(size: 10, design: .monospaced)
    public static let label      = Font.system(size: 10, weight: .bold, design: .monospaced)
    public static let statValue  = Font.system(size: 22, weight: .semibold, design: .monospaced)
}

/// 大写 + tracking 的标签文字, 用于 section header
public struct LabelText: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = HVMColor.textTertiary) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text.uppercased())
            .font(HVMFont.label)
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// 脉冲 running 点
public struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @State private var animating = false

    public init(color: Color = HVMColor.statusRunning, size: CGFloat = 6) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.6, height: size * 2.6)
                .scaleEffect(animating ? 1.2 : 0.8)
                .opacity(animating ? 0 : 1)
                .animation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: animating
                )
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.6), radius: size * 0.8)
        }
        .frame(width: size * 3, height: size * 3)
        .onAppear { animating = true }
    }
}

/// terminal 风 section container: 顶部 `┌─ TITLE ──` 边角, 内容包在细边框里
public struct TerminalSection<Content: View>: View {
    let title: String
    let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            HStack(spacing: 6) {
                Text("┌─")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.border)
                Text(title.uppercased())
                    .font(HVMFont.label)
                    .tracking(1.6)
                    .foregroundStyle(HVMColor.textSecondary)
                Text(String(repeating: "─", count: 64))
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.border)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            content()
                .padding(.leading, HVMSpace.sm)
        }
    }
}
