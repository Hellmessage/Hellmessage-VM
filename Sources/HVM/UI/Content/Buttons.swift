// Buttons.swift
// Hacker 风按钮: outline / filled 二态, accent 青绿单色

import SwiftUI

public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(HVMColor.textOnAccent)
            .padding(.horizontal, HVMSpace.lg)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(configuration.isPressed
                          ? HVMColor.accent.opacity(0.80)
                          : HVMColor.accent)
            )
            .shadow(color: HVMColor.accent.opacity(configuration.isPressed ? 0 : 0.25),
                    radius: 6, x: 0, y: 2)
            .contentShape(Rectangle())
    }
}

public struct GhostButtonStyle: ButtonStyle {
    var destructive: Bool = false
    public init(destructive: Bool = false) { self.destructive = destructive }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(destructive ? HVMColor.danger : HVMColor.textPrimary)
            .padding(.horizontal, HVMSpace.lg)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(configuration.isPressed
                          ? HVMColor.bgSelected
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .stroke(destructive ? HVMColor.danger.opacity(0.5)
                                        : HVMColor.border,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

public struct IconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(HVMColor.textSecondary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(configuration.isPressed ? HVMColor.bgSelected : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

/// 空状态居中大号 CTA, 比 PillAccent 更粗更带 glow
public struct HeroCTAStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .tracking(2.0)
            .foregroundStyle(HVMColor.accent)
            .padding(.horizontal, HVMSpace.xl)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(configuration.isPressed
                          ? HVMColor.accent.opacity(0.20)
                          : HVMColor.accentMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .stroke(HVMColor.accent, lineWidth: 1)
            )
            .shadow(color: HVMColor.accent.opacity(configuration.isPressed ? 0.15 : 0.35),
                    radius: 12, x: 0, y: 0)
            .contentShape(Rectangle())
    }
}

/// 顶栏 "+ NEW" 这种 pill 按钮
public struct PillAccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(HVMColor.accent)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(configuration.isPressed
                               ? HVMColor.accent.opacity(0.18)
                               : HVMColor.accentMuted)
            )
            .overlay(
                Capsule().stroke(HVMColor.accent.opacity(0.45), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}
