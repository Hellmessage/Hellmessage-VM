// Buttons.swift
// 按钮 style 集合. 专业工具风: SF Pro / 句首大写 / 无 glow / 蓝 accent.
// 业务代码必须从这五种里挑一个用, 不允许裸 Button 不带 buttonStyle.

import SwiftUI

/// 主按钮: 蓝色实心, 用于"创建 / 保存 / 启动" 等正向主操作.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HVMFont.bodyBold)
            .foregroundStyle(HVMColor.textOnAccent)
            .padding(.horizontal, HVMSpace.lg)
            .padding(.vertical, HVMSpace.buttonPadV7)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(configuration.isPressed
                          ? HVMColor.accent.opacity(0.80)
                          : HVMColor.accent)
            )
            .contentShape(Rectangle())
    }
}

/// 次按钮: 透明 + 1px 边. 用于 "取消 / 暂停 / 停止 / 弹出 ISO" 等次级操作.
/// destructive=true 时改红字红边, 用于 "删除 / Kill" 等破坏性操作.
public struct GhostButtonStyle: ButtonStyle {
    var destructive: Bool = false
    public init(destructive: Bool = false) { self.destructive = destructive }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HVMFont.bodyMedium)
            .foregroundStyle(destructive ? HVMColor.danger : HVMColor.textPrimary)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, HVMSpace.buttonPadV6)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(configuration.isPressed
                          ? (destructive ? HVMColor.danger.opacity(0.12) : HVMColor.bgHover)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .stroke(destructive ? HVMColor.danger.opacity(0.55)
                                        : HVMColor.border,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// 仅图标按钮 (顶栏 X / 刷新 / etc).
public struct IconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HVMFont.caption)
            .foregroundStyle(HVMColor.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(configuration.isPressed ? HVMColor.bgHover : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

/// 空状态居中 CTA. 比 Primary 更大更醒目.
public struct HeroCTAStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HVMFont.heading)
            .foregroundStyle(HVMColor.textOnAccent)
            .padding(.horizontal, HVMSpace.xl)
            .padding(.vertical, HVMSpace.buttonPadV10)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(configuration.isPressed
                          ? HVMColor.accent.opacity(0.80)
                          : HVMColor.accent)
            )
            .contentShape(Rectangle())
    }
}

/// 顶栏 "+ New VM" 这种 pill 按钮. 蓝底白字, 比 Primary 更小巧.
public struct PillAccentButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HVMFont.captionEm)
            .foregroundStyle(HVMColor.textOnAccent)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, HVMSpace.buttonPadV5)
            .background(
                Capsule().fill(configuration.isPressed
                               ? HVMColor.accent.opacity(0.80)
                               : HVMColor.accent)
            )
            .contentShape(Rectangle())
    }
}
