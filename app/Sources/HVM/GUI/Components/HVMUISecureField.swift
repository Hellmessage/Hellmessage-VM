// HVMUISecureField.swift — 新 GUI 密码 / 敏感文本字段.
//
// 跟 HVMUI.TextField 同套 chrome (复用 FieldChrome) 但底层是 NSSecureTextField (本质禁 IME).
// showToggle = true 时右侧加 eye 按钮切显隐 (reveal 态切到明文 TextField).
// 用法: HVMUI.SecureField("密码", text: $pwd, probeID: "dialog.encrypt.field.password")


import SwiftUI
import AppKit
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
    private let autoFocus: Bool
    private let probeID: String
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
         autoFocus: Bool = false,
         probeID: String,
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
        self.autoFocus = autoFocus
        self.probeID = probeID
        self.onSubmit = onSubmit
    }

    @FocusState private var isFocused: Bool
    /// 密文态走 NSSecureTextField (本质禁 IME), 它的 focus 状态由这里跟踪 (FieldChrome 焦点环用)
    @State private var secureFocused = false
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
                    isFocused: isFocused || secureFocused,
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

            // 明文态: SwiftUI TextField (showToggle reveal); 密文态: NSSecureTextField (本质禁 IME)
            if isRevealed {
                SwiftUI.TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(size.font)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                    .tint(HVMTheme.color.accent)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            } else {
                MacSecureField(text: $text,
                               isFocused: $secureFocused,
                               placeholder: placeholder,
                               font: size.nsFont,
                               textColor: NSColor(HVMTheme.color.textPrimary),
                               autoFocus: autoFocus && !isDisabled,
                               onSubmit: onSubmit)
                    .frame(height: size.height - 2)
            }

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
        // padding + frame 内化, 让 hit test 覆盖整个 padding 区
        .padding(.horizontal, size.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: size.height)
        .contentShape(Rectangle())
    }
}

}  // extension HVMUI 结束

/// 真 NSSecureTextField 包装 — SwiftUI SecureField 在 macOS 仍弹 IME 候选;
/// NSSecureTextField 本质禁 IME (安全文本输入强制 ASCII/Roman).
private struct MacSecureField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let font: NSFont
    let textColor: NSColor
    let autoFocus: Bool
    let onSubmit: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let f = NSSecureTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none          // 焦点环走外层 FieldChrome
        f.placeholderString = placeholder
        f.font = font
        f.textColor = textColor
        f.delegate = context.coordinator
        f.lineBreakMode = .byClipping
        f.usesSingleLineMode = true
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if autoFocus {
            // 密码 dialog 首字段: 出现即聚焦 (NSSecureTextField 聚焦时 macOS 自动禁 IME)
            DispatchQueue.main.async { [weak f] in f?.window?.makeFirstResponder(f) }
        }
        return f
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.font = font
        nsView.textColor = textColor
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacSecureField
        init(_ p: MacSecureField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }
        func controlTextDidBeginEditing(_ obj: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ obj: Notification) { parent.isFocused = false }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

private extension HVMUI.FieldSize {
    /// NSSecureTextField 用的 NSFont (跟 SwiftUI font 档位对齐: sm=13 / md=14 medium / lg=18 semibold)
    var nsFont: NSFont {
        switch self {
        case .sm: return .systemFont(ofSize: 13)
        case .md: return .systemFont(ofSize: 14, weight: .medium)
        case .lg: return .systemFont(ofSize: 18, weight: .semibold)
        }
    }
}

private struct ProbeSecureFieldModifier: ViewModifier {
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

