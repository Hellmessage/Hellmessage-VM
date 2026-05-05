// HVMTextField.swift
// 自绘输入框. 视觉与 HVMFormSelect / HVMFormMenuField 同源 (圆角 8 / bgCardHi / 1px border / 蓝聚焦环).
// 内部仍用 SwiftUI TextField 取焦点和输入, 外层手画 background + overlay.
//
// 用法:
//   HVMTextField("VM name", text: $name)                                    // 普通
//   HVMTextField("Path", text: $path, error: pathError)                     // 错误态: 红边 + 下方 hint
//   HVMTextField("ISO path", text: $iso, suffix: "GB")                      // 尾置单位
//   HVMTextField("Path", text: $path, action: ("…", { pickFile() }))        // 尾置 action 按钮
//
// 强制约束 (CLAUDE.md): 业务代码禁止直接用 SwiftUI TextField/SecureField.

import AppKit
import SwiftUI

public struct HVMTextField: View {
    public enum Variant {
        case plain      // 普通文本
        case secure     // 密码态
    }

    public struct ActionButton {
        public let label: String
        public let handler: () -> Void
        public init(_ label: String, handler: @escaping () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    private let placeholder: String
    @Binding private var text: String
    private let variant: Variant
    private let suffix: String?
    private let action: ActionButton?
    private let error: String?
    private let multilineAlign: TextAlignment

    @FocusState private var focused: Bool

    public init(
        _ placeholder: String,
        text: Binding<String>,
        variant: Variant = .plain,
        suffix: String? = nil,
        action: ActionButton? = nil,
        error: String? = nil,
        textAlign: TextAlignment = .leading
    ) {
        self.placeholder = placeholder
        self._text = text
        self.variant = variant
        self.suffix = suffix
        self.action = action
        self.error = error
        self.multilineAlign = textAlign
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HVMSpace.sm) {
                fieldRow

                if let action {
                    Button(action: action.handler) {
                        Text(action.label)
                            .font(HVMFont.body)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            if let error, !error.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(HVMFont.tiny)
                        .foregroundStyle(HVMColor.danger)
                    Text(error)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.danger)
                }
            }
        }
    }

    @ViewBuilder
    private var fieldRow: some View {
        HStack(spacing: HVMSpace.sm) {
            innerField
            if let suffix {
                Text(suffix)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
            }
        }
        .padding(.horizontal, HVMSpace.md)
        .padding(.vertical, HVMSpace.buttonPadV7)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .fill(HVMColor.bgCardHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(borderColor, lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: error != nil)
    }

    @ViewBuilder
    private var innerField: some View {
        Group {
            switch variant {
            case .plain:
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
                    .tint(HVMColor.accent)
                    .multilineTextAlignment(multilineAlign)
                    .focused($focused)
            case .secure:
                // SwiftUI SecureField 在 macOS 14+ 不禁 IME — 中文输入法激活时仍弹候选词,
                // 用户能用中文输密码 (实际写入 text 的还是英文 unicode 或 IME composed string,
                // 但 UI 体验差且容易误输). 走 NSViewRepresentable 包 NSSecureTextField +
                // allowedInputSourceLocales=[Roman] 限制只接英文 / 数字 / 符号输入源.
                NoIMESecureTextField(placeholder: placeholder, text: $text, focused: $focused)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var borderColor: Color {
        if error != nil, !(error ?? "").isEmpty { return HVMColor.danger }
        if focused { return HVMColor.borderAccent }
        return HVMColor.border
    }
}

// MARK: - 禁 IME 的 SecureField 实现
//
// SwiftUI SecureField 在 macOS 上仍允许 IME (中文输入法弹候选词), 走 NSViewRepresentable
// 包 NSSecureTextField + allowedInputSourceLocales=[Roman] 强制只接英文 / 数字 / 符号.
// macOS 系统密码框 (登录 / 解锁钥匙串) 也是用这种方式禁 IME.
private struct NoIMESecureTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    func makeNSView(context: Context) -> NSSecureTextField {
        let tf = NSSecureTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.delegate = context.coordinator
        // allowedInputSourceLocales 是 NSText 属性, 必须在 fieldEditor 创建后设 —
        // 走 controlTextDidBeginEditing 拿 currentEditor() 设, 见 Coordinator.
        return tf
    }

    func updateNSView(_ tf: NSSecureTextField, context: Context) {
        if tf.stringValue != text {
            tf.stringValue = text
        }
        tf.placeholderString = placeholder
        // SwiftUI .focused -> AppKit firstResponder 同步
        if focused, tf.window?.firstResponder !== tf.currentEditor() {
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focused: $focused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @FocusState.Binding var focused: Bool

        init(text: Binding<String>, focused: FocusState<Bool>.Binding) {
            self._text = text
            self._focused = focused
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let tf = notification.object as? NSTextField else { return }
            text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // 在 fieldEditor 上设 allowedInputSourceLocales 才能禁 IME — 编辑开始才能拿到.
            // currentEditor() 实际返回 NSTextView (NSText 子类), allowedInputSourceLocales
            // 是 NSTextView 的属性.
            if let tf = notification.object as? NSTextField,
               let editor = tf.currentEditor() as? NSTextView {
                editor.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
            }
            focused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            focused = false
        }

        // Return / Tab 走 SwiftUI .onSubmit / .keyboardShortcut 链路, 不在这里拦
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // 让 NSTextView 默认处理回车 / tab — SwiftUI .onSubmit 仍能收到 (来自
            // .keyboardShortcut(.return)). 返回 false 不拦.
            return false
        }
    }
}
