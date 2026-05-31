// HVMUIButton.swift — 新 GUI 按钮组件.
//
// 5 variant: primary (青底主操作) / secondary (边框次操作) / ghost (hover 才出 bg) /
//            destructive (error 边框危险操作) / icon (纯图标正方形).
// 3 size: .sm 24 高 / .md 32 高 (default) / .lg 40 高.
// 交互: hover 色变, press scale 0.97, focus ring (键盘 Tab 才显), loading 换 spinner.
//
// probe: probeID 非 disabled + 非 loading 时挂 .button(action), hvm-dbg gui click 走 action.


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
    private let fillWidth: Bool
    private let probeID: String
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
         fillWidth: Bool = false,
         probeID: String,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.icon = icon
        self.variant = variant
        self.iconPosition = iconPosition
        self.size = size
        self.isDisabled = disabled
        self.isLoading = isLoading
        self.fillWidth = fillWidth
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
         probeID: String,
         probeLabel: String? = nil,
         action: @escaping @MainActor @Sendable () -> Void) {
        self.label = nil
        self.icon = icon
        self.variant = variant
        self.iconPosition = .leading
        self.size = size
        self.isDisabled = disabled
        self.isLoading = isLoading
        self.fillWidth = false   // 纯 icon 不支持 fillWidth
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
                   maxWidth: fillWidth ? .infinity : nil,
                   minHeight: size.height)
            .foregroundStyle(textColor)
            .background(bgColor)
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .overlay(focusRing)
            // disabled / loading 走整体降透 (保留 variant 身份感, 不灰底失去 primary 视觉)
            .opacity(buttonOpacity)
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

        if !isDisabled, !isLoading {
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

    /// disabled 0.4 / loading 0.65 (比 disabled 可读, 暗示 "忙" 非 "禁") / active 1.0.
    private var buttonOpacity: Double {
        if isDisabled { return 0.4 }
        if isLoading  { return 0.65 }
        return 1.0
    }

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

/// 按钮 press 反馈: scale 0.97 spring (hover 走色变, press 走形变, 两通道独立).
private struct HVMButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(HVMTheme.motion.pressSpring, value: configuration.isPressed)
    }
}

