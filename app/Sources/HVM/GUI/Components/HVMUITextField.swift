// HVMUITextField.swift — 新 GUI 文本输入字段.
//
// 3 size: .sm 28 高 / .md 36 高 (default) / .lg 44 高. 支持 icon / suffix / errorMessage / loading.
// 视觉: hover 提亮 / focus ring / error 红框 + 下方红字 / disabled opacity 0.4.
// 用法: HVMUI.TextField("名称", text: $name, placeholder: "我的 VM", probeID: "...")
//
// probe: 挂 .textField(getter, setter), hvm-dbg gui type --identifier X --text Y 走 setter 改 binding.


import SwiftUI
import HVMGuiProbe

extension HVMUI {

/// 字段 size 档 — TextField / SecureField / Select 共用
enum FieldSize {
    case sm, md, lg

    var height: CGFloat {
        switch self {
        case .sm: return 28
        case .md: return 36
        case .lg: return 44
        }
    }

    var font: Font {
        switch self {
        case .sm: return HVMTheme.font.base
        case .md: return HVMTheme.font.md
        case .lg: return HVMTheme.font.lg
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: return HVMTheme.space.sm
        case .md: return HVMTheme.space.md
        case .lg: return HVMTheme.space.lg
        }
    }

    var spinnerScale: CGFloat {
        switch self {
        case .sm: return 0.5
        case .md: return 0.6
        case .lg: return 0.8
        }
    }
}

struct TextField: View {
    private let label: String?
    private let placeholder: String
    @Binding private var text: String
    private let size: FieldSize
    private let icon: String?
    private let suffix: String?
    private let errorMessage: String?
    private let isLoading: Bool
    private let isDisabled: Bool
    private let probeID: String
    private let onSubmit: (@MainActor @Sendable () -> Void)?

    init(_ label: String? = nil,
         text: Binding<String>,
         placeholder: String = "",
         size: FieldSize = .md,
         icon: String? = nil,
         suffix: String? = nil,
         errorMessage: String? = nil,
         isLoading: Bool = false,
         disabled: Bool = false,
         probeID: String,
         onSubmit: (@MainActor @Sendable () -> Void)? = nil) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.size = size
        self.icon = icon
        self.suffix = suffix
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.isDisabled = disabled
        self.probeID = probeID
        self.onSubmit = onSubmit
    }

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
            if let label {
                SwiftUI.Text(label)
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
            }

            fieldBody
                .modifier(FieldChrome(
                    size: size,
                    isFocused: isFocused,
                    isHovered: isHovered && !isDisabled,
                    isError: errorMessage != nil,
                    isDisabled: isDisabled
                ))
                .onHover { isHovered = $0 }
                .opacity(isDisabled ? 0.4 : 1.0)
                .allowsHitTesting(!isDisabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label ?? placeholder)
                .accessibilityHint(errorMessage ?? placeholder)
                .modifier(ProbeTextFieldModifier(
                    probeID: probeID,
                    label: label ?? placeholder,
                    text: $text,
                    isDisabled: isDisabled
                ))

            if let errorMessage {
                SwiftUI.Text(errorMessage)
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
                    .transition(.opacity)
            }
        }
        .animation(HVMTheme.motion.easeOut, value: errorMessage != nil)
    }

    private var fieldBody: some View {
        HStack(spacing: HVMTheme.space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(size.font)
                    .foregroundStyle(HVMTheme.color.textSecondary)
            }

            SwiftUI.TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(size.font)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .tint(HVMTheme.color.accent)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if let suffix {
                SwiftUI.Text(suffix)
                    .font(size.font)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(size.spinnerScale)
                    .progressViewStyle(.circular)
            }
        }
        // padding + frame 内化, 让 hit test 覆盖整个 padding 区
        .padding(.horizontal, size.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: size.height)
        .contentShape(Rectangle())
    }
}

/// 字段外框 modifier — TextField / SecureField / Select 共享. 仅管 bg / border / focus ring,
/// padding + frame + contentShape 留给业务侧, 让 hit test 覆盖整个 padding 区.
struct FieldChrome: ViewModifier {
    let size: FieldSize
    let isFocused: Bool
    let isHovered: Bool
    let isError: Bool
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .background(bgLayer)
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.md))
            .overlay(borderLayer)
            .overlay(focusRing)
            .animation(HVMTheme.motion.easeOutFast, value: isHovered)
            .animation(HVMTheme.motion.easeOut, value: isFocused)
            .animation(HVMTheme.motion.easeOut, value: isError)
    }

    private var bgLayer: some View {
        ZStack {
            (isFocused ? HVMTheme.color.bgOverlay : HVMTheme.color.bgRaised)
            if isHovered && !isFocused {
                HVMTheme.color.bgHover
            }
        }
    }

    private var borderLayer: some View {
        RoundedRectangle(cornerRadius: HVMTheme.radius.md)
            .stroke(borderColor, lineWidth: HVMTheme.border.hairline)
    }

    private var borderColor: Color {
        if isError { return HVMTheme.color.borderError }
        if isFocused { return HVMTheme.color.transparent }
        return HVMTheme.color.borderDefault
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused && !isError {
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .stroke(HVMTheme.color.borderFocus, lineWidth: HVMTheme.border.focus)
                .transition(.opacity)
        }
    }
}

}  // extension HVMUI 结束

/// Probe 集成 modifier — 未 disabled 时挂 .textField(getter 读 / setter 写 binding).
private struct ProbeTextFieldModifier: ViewModifier {
    let probeID: String
    let label: String
    @Binding var text: String
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if !isDisabled {
            content.hvmProbe(
                id: probeID,
                label: label,
                action: .textField(
                    getter: { text },
                    setter: { text = $0 }
                )
            )
        } else {
            content
        }
    }
}

