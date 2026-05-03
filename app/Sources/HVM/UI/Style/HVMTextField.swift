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
            case .secure:
                SecureField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(HVMFont.body)
        .foregroundStyle(HVMColor.textPrimary)
        .tint(HVMColor.accent)
        .multilineTextAlignment(multilineAlign)
        .focused($focused)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var borderColor: Color {
        if error != nil, !(error ?? "").isEmpty { return HVMColor.danger }
        if focused { return HVMColor.borderAccent }
        return HVMColor.border
    }
}
