// HVMUISecureField.swift — 新 GUI 密码 / 敏感文本字段 (PR-C2)
//
// 跟 HVMUI.TextField 同套 chrome (复用 HVMUI.FieldChrome modifier) 但底层是 SwiftUI
// SecureField (NSSecureTextField); 加 show/hide toggle 切显隐.
//
// 用法:
//   HVMUI.SecureField("密码", text: $pwd, placeholder: "请输入")
//   HVMUI.SecureField("密码", text: $pwd, showToggle: true,
//                     probeID: "dialog.encrypt.field.password")
//
// showToggle = true 时右侧加 eye / eye.slash icon 按钮; 点击后字段切到 TextField
// (明文) 直到再次点击. probe 仍按 SecureField 通路, getter/setter 透当前 binding
// (不论明文还是密文 SwiftUI 内部都是 String).

#if NEW_GUI

import SwiftUI
import HVMGuiProbe

extension HVMUI {

struct SecureField: View {
    private let label: String?
    private let placeholder: String
    @Binding private var text: String
    private let size: FieldSize
    private let icon: String?
    private let showToggle: Bool
    private let errorMessage: String?
    private let isLoading: Bool
    private let isDisabled: Bool
    private let probeID: String?
    private let onSubmit: (@MainActor @Sendable () -> Void)?

    init(_ label: String? = nil,
         text: Binding<String>,
         placeholder: String = "",
         size: FieldSize = .md,
         icon: String? = nil,
         showToggle: Bool = false,
         errorMessage: String? = nil,
         isLoading: Bool = false,
         disabled: Bool = false,
         probeID: String? = nil,
         onSubmit: (@MainActor @Sendable () -> Void)? = nil) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.size = size
        self.icon = icon
        self.showToggle = showToggle
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.isDisabled = disabled
        self.probeID = probeID
        self.onSubmit = onSubmit
    }

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var isRevealed = false   // showToggle 切换出来的明文态

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
                .modifier(ProbeSecureFieldModifier(
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

            // 明文 / 密文动态切换. focus 状态由 @FocusState 共享, 切换后 focus 不丢
            Group {
                if isRevealed {
                    SwiftUI.TextField(placeholder, text: $text)
                } else {
                    SwiftUI.SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(size.font)
            .foregroundStyle(HVMTheme.color.textPrimary)
            .tint(HVMTheme.color.accent)
            .focused($isFocused)
            .onSubmit { onSubmit?() }

            if showToggle {
                SwiftUI.Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(size.font)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "隐藏密码" : "显示密码")
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(size.spinnerScale)
                    .progressViewStyle(.circular)
            }
        }
    }
}

}  // extension HVMUI 结束

private struct ProbeSecureFieldModifier: ViewModifier {
    let probeID: String?
    let label: String
    @Binding var text: String
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if let probeID, !isDisabled {
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

#endif
