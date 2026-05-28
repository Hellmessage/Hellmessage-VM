// HVMButton.swift — 新 GUI 按钮组件 (PR-C1)
//
// 5 variant (互斥):
//   .primary       — accent 青底, 主操作 (Dialog 主按钮 / 保存 / 创建)
//   .secondary     — 边框 + 透明底, 次要操作 (取消 / 返回)
//   .ghost         — 无边框, hover 才出 bg, 弱化操作 (icon toolbar / tab)
//   .destructive   — 边框 error 色, 危险操作 (确认前的删除 / 加密 reset)
//   .icon          — 纯图标 32×32, ghost 同款外观但更紧凑 (Dialog 关闭 X / titlebar)
//
// 用法:
//   HVMButton("保存", variant: .primary, probeID: "dialog.X.button.save") { save() }
//   HVMButton("删除", variant: .destructive, icon: "trash.fill") { delete() }
//   HVMButton(icon: "gear", variant: .ghost, probeID: "toolbar.button.settings") { ... }
//
// 状态:
//   - hover  : bg 加深 120ms ease-out (HVMTheme.motion.easeOutFast)
//   - press  : scale 0.97 spring (HVMTheme.motion.pressSpring)
//   - disabled: opacity 0.4, 不接 hover / probe, 不可点击
//
// probe: probeID 非 nil 时自动 .hvmProbe(id:label:action:.button(...)). 业务侧不用
// 重写 action — modifier 内部把 action closure 透传给 ProbeRegistry, hvm-dbg gui
// click 时拿同一 closure 调.

#if NEW_GUI

import SwiftUI
import HVMGuiProbe

struct HVMButton: View {
    enum Variant {
        case primary, secondary, ghost, destructive, icon
    }

    private let label: String?
    private let icon: String?      // SF Symbol name
    private let variant: Variant
    private let isDisabled: Bool
    private let probeID: String?
    private let probeLabel: String?
    // action 标 @MainActor + @Sendable, 跟 ProbeAction.button 签名对齐, 让 .button(action)
    // 不需要再 wrap. SwiftUI View body 本身 @MainActor, 所有业务侧 closure 默认满足.
    private let action: @MainActor @Sendable () -> Void

    @State private var hovered = false

    // 文字 (+ 可选 icon) 按钮
    init(_ label: String,
         variant: Variant = .primary,
         icon: String? = nil,
         disabled: Bool = false,
         probeID: String? = nil,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.icon = icon
        self.variant = variant
        self.isDisabled = disabled
        self.probeID = probeID
        self.probeLabel = probeLabel
        self.action = action
    }

    // 纯 icon 按钮 (默认 .icon variant, 也可显式传 .ghost 给 toolbar 用)
    init(icon: String,
         variant: Variant = .icon,
         disabled: Bool = false,
         probeID: String? = nil,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = nil
        self.icon = icon
        self.variant = variant
        self.isDisabled = disabled
        self.probeID = probeID
        self.probeLabel = probeLabel
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: HVMTheme.space.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(HVMTheme.font.md)
                }
                if let label {
                    Text(label)
                        .font(HVMTheme.font.md)
                }
            }
            .padding(.horizontal, variant == .icon ? 0 : HVMTheme.space.md)
            .frame(minWidth: variant == .icon ? 32 : 0, minHeight: 32)
            .foregroundStyle(textColor)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(HVMButtonPressStyle())
        .disabled(isDisabled)
        .onHover { if !isDisabled { hovered = $0 } }
        .animation(HVMTheme.motion.easeOutFast, value: hovered)

        // probeID 非 nil 时挂 probe; 同一 action closure 给 hvm-dbg gui click 用
        if let probeID, !isDisabled {
            button.hvmProbe(
                id: probeID,
                label: probeLabel ?? label ?? icon ?? "",
                action: .button(action)
            )
        } else {
            button
        }
    }

    // MARK: - 外观计算 (variant + hover 矩阵, 全 token)

    private var textColor: Color {
        switch variant {
        case .primary:
            return HVMTheme.color.textOnAccent
        case .secondary:
            return HVMTheme.color.textPrimary
        case .ghost, .icon:
            return hovered ? HVMTheme.color.textPrimary : HVMTheme.color.textSecondary
        case .destructive:
            return HVMTheme.color.error
        }
    }

    private var bgColor: Color {
        switch variant {
        case .primary:
            return hovered ? HVMTheme.color.accentHover : HVMTheme.color.accent
        case .secondary, .ghost, .icon:
            return hovered ? HVMTheme.color.bgHover : HVMTheme.color.transparent
        case .destructive:
            return hovered ? HVMTheme.color.destructiveHover : HVMTheme.color.transparent
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary, .ghost, .icon:
            return HVMTheme.color.transparent
        case .secondary:
            return HVMTheme.color.borderDefault
        case .destructive:
            return HVMTheme.color.borderError
        }
    }

    private var borderWidth: CGFloat {
        switch variant {
        case .primary, .ghost, .icon:
            return 0
        case .secondary, .destructive:
            return HVMTheme.border.hairline
        }
    }
}

/// 按钮 press 反馈: scale 0.97 spring. 不影响其它外观, 仅做交互动效.
/// 不用 .scaleEffect on hover state — hover 走色变, press 走形变, 两通道独立.
private struct HVMButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(HVMTheme.motion.pressSpring, value: configuration.isPressed)
    }
}

#endif
