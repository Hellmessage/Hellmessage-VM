// HVMUIButton.swift — 新 GUI 按钮组件 (PR-C1b 按 R1-R9 重做)
//
// 5 variant (互斥):
//   .primary       — accent 青底, 主操作 (Dialog 主按钮 / 保存 / 创建)
//   .secondary     — 边框 + 透明底, 次要操作 (取消 / 返回)
//   .ghost         — 无边框, hover 才出 bg, 弱化操作 (icon toolbar / tab)
//   .destructive   — 边框 error 色, 危险操作 (确认前的删除 / 加密 reset)
//   .icon          — 纯图标 size×size, ghost 同款外观但正方形 (Dialog 关闭 X / titlebar)
//
// 3 档 size:
//   .sm — 24 高 / font sm / padding sm (icon-only 24×24; toolbar / 列表行内联用)
//   .md — 32 高 / font md / padding md (default; 表单 / dialog 主流)
//   .lg — 40 高 / font md / padding lg (hero CTA / 单按钮 dialog)
//
// 用法:
//   HVMUI.Button("保存", variant: .primary) { save() }
//   HVMUI.Button("删除", variant: .destructive, icon: "trash") { delete() }
//   HVMUI.Button("装机", variant: .primary, icon: "play.fill",
//                iconPosition: .trailing, size: .lg) { install() }
//   HVMUI.Button("提交中", variant: .primary, isLoading: true) { }
//   HVMUI.Button(icon: "gear", variant: .ghost, size: .sm) { ... }
//
// 视觉 (Linear+):
//   - hover  : bg 加深 120ms easeOutFast
//   - press  : scale 0.97 spring (HVMButtonPressStyle)
//   - focus  : 外圈 2px borderFocus ring 渐现 200ms (键盘 Tab 才显; click 不出)
//   - loading: icon 位置换 ProgressView; action 跳过, hover 跳过
//   - disabled: bg / fg 改 dim token, 不再走整体 .opacity(0.4)
//     (深底上整 opacity 会让按钮跟主底压平; 改用 textTertiary fg + bgDisabled bg)
//
// 键盘 + a11y:
//   - SwiftUI.Button + .focused($isFocused) + .accessibilityLabel
//   - Space / Return 自带触发
//   - loading / disabled 时不可点
//
// probe: probeID 非 nil + 非 disabled + 非 loading 时挂 .button(action).
// hvm-dbg gui click --identifier X 走 action.

#if NEW_GUI

import SwiftUI
import HVMGuiProbe

extension HVMUI {

struct Button: View {
    enum Variant {
        case primary, secondary, ghost, destructive, icon
    }

    enum ButtonSize {
        case sm, md, lg

        var height: CGFloat {
            switch self {
            case .sm: return 24
            case .md: return 32
            case .lg: return 40
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .sm: return HVMTheme.space.sm
            case .md: return HVMTheme.space.md
            case .lg: return HVMTheme.space.lg
            }
        }

        var font: Font {
            switch self {
            case .sm: return HVMTheme.font.sm
            case .md: return HVMTheme.font.md
            case .lg: return HVMTheme.font.md
            }
        }

        var iconFont: Font {
            switch self {
            case .sm: return HVMTheme.font.sm
            case .md: return HVMTheme.font.md
            case .lg: return HVMTheme.font.lg
            }
        }

        var spinnerScale: CGFloat {
            switch self {
            case .sm: return 0.5
            case .md: return 0.6
            case .lg: return 0.7
            }
        }
    }

    enum IconPosition {
        case leading, trailing
    }

    private let label: String?
    private let icon: String?
    private let variant: Variant
    private let size: ButtonSize
    private let iconPosition: IconPosition
    private let isDisabled: Bool
    private let isLoading: Bool
    private let probeID: String?
    private let probeLabel: String?
    // action @MainActor @Sendable, 跟 ProbeAction.button 签名对齐.
    private let action: @MainActor @Sendable () -> Void

    @State private var hovered = false
    @FocusState private var isFocused: Bool

    // 文字 (+ 可选 icon) 按钮
    init(_ label: String,
         variant: Variant = .primary,
         icon: String? = nil,
         iconPosition: IconPosition = .leading,
         size: ButtonSize = .md,
         disabled: Bool = false,
         isLoading: Bool = false,
         probeID: String? = nil,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.icon = icon
        self.variant = variant
        self.iconPosition = iconPosition
        self.size = size
        self.isDisabled = disabled
        self.isLoading = isLoading
        self.probeID = probeID
        self.probeLabel = probeLabel
        self.action = action
    }

    // 纯 icon 按钮 (默认 .icon variant)
    init(icon: String,
         variant: Variant = .icon,
         size: ButtonSize = .md,
         disabled: Bool = false,
         isLoading: Bool = false,
         probeID: String? = nil,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = nil
        self.icon = icon
        self.variant = variant
        self.iconPosition = .leading
        self.size = size
        self.isDisabled = disabled
        self.isLoading = isLoading
        self.probeID = probeID
        self.probeLabel = probeLabel
        self.action = action
    }

    var body: some View {
        let button = SwiftUI.Button(action: {
            if !isLoading { action() }
        }) {
            HStack(spacing: HVMTheme.space.sm) {
                if iconPosition == .leading {
                    iconOrSpinner
                }
                if let label {
                    Text(label)
                        .font(size.font)
                }
                if iconPosition == .trailing {
                    iconOrSpinner
                }
            }
            .padding(.horizontal, variant == .icon ? 0 : size.horizontalPadding)
            .frame(minWidth: variant == .icon ? size.height : 0,
                   minHeight: size.height)
            .foregroundStyle(textColor)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .overlay(focusRing)
            .animation(HVMTheme.motion.easeOutFast, value: hovered)
            .animation(HVMTheme.motion.easeOut, value: isFocused)
            .animation(HVMTheme.motion.easeOut, value: isLoading)
        }
        .buttonStyle(HVMButtonPressStyle())
        .disabled(isDisabled || isLoading)
        .focused($isFocused)
        .onHover { if !isDisabled && !isLoading { hovered = $0 } }
        .accessibilityLabel(label ?? icon ?? "")
        .accessibilityHint(isLoading ? "正在处理" : "")

        if let probeID, !isDisabled, !isLoading {
            button.hvmProbe(
                id: probeID,
                label: probeLabel ?? label ?? icon ?? "",
                action: .button(action)
            )
        } else {
            button
        }
    }

    @ViewBuilder
    private var iconOrSpinner: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(size.spinnerScale)
                .progressViewStyle(.circular)
                .frame(width: 16, height: 16)
        } else if let icon {
            Image(systemName: icon)
                .font(size.iconFont)
        }
    }

    // MARK: - 外观计算 (variant + state 矩阵, 全 token)

    private var textColor: Color {
        if isDisabled { return HVMTheme.color.textTertiary }
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
        if isDisabled {
            switch variant {
            case .primary:
                return HVMTheme.color.bgDisabled
            case .secondary, .ghost, .icon, .destructive:
                return HVMTheme.color.transparent
            }
        }
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
        if isDisabled {
            switch variant {
            case .primary, .ghost, .icon:
                return HVMTheme.color.transparent
            case .secondary, .destructive:
                return HVMTheme.color.borderDefault
            }
        }
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

    @ViewBuilder
    private var focusRing: some View {
        if isFocused && !isDisabled {
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .stroke(HVMTheme.color.borderFocus, lineWidth: HVMTheme.border.focus)
                .transition(.opacity)
        }
    }
}

}  // extension HVMUI 结束

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
