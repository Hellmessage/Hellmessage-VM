// HVMUIInputDialog.swift — 新 GUI 输入表单 dialog. 多字段 (含 secure 密码) + 实时 validation.
//
// 关闭路径 → 结果: 主按钮 → .submitted(values); 取消 / X / Esc / dismissAll → .cancelled.
// validate 闭包接收当前 [String] 返 .valid / .invalid(msg), 字段变化即 re-validate,
//   .invalid 时主按钮 disabled + 红字; nil 表示不验证.
//
// 业务侧首选 async API: dialog.input(title:fields:validate:probeID:).
// Probe id 派生: <probeID>.field.<idx> / .confirm / .cancel / .close.


import SwiftUI

extension HVMUI {

/// 输入字段配置 — InputDialog 内每个字段用一个 InputField 描述
struct InputField: Sendable {
    let label: String
    let placeholder: String
    let initialText: String
    let secure: Bool
    let icon: String?

    init(label: String,
         placeholder: String = "",
         initialText: String = "",
         secure: Bool = false,
         icon: String? = nil) {
        self.label = label
        self.placeholder = placeholder
        self.initialText = initialText
        self.secure = secure
        self.icon = icon
    }
}

/// 验证结果 — validate 闭包返回
enum InputValidation: Sendable {
    case valid
    case invalid(String)
}

/// 提交结果 — async API 返回
enum InputResult: Sendable {
    case submitted([String])
    case cancelled
}

struct InputDialog: View {
    private let title: String
    private let fields: [InputField]
    private let validate: (@MainActor @Sendable ([String]) -> InputValidation)?
    private let confirmLabel: String
    private let cancelLabel: String
    private let probeID: String
    private let onResult: @MainActor @Sendable (InputResult) -> Void

    @State private var values: [String]
    @State private var validationError: String?

    init(title: String,
         fields: [InputField],
         validate: (@MainActor @Sendable ([String]) -> InputValidation)? = nil,
         confirmLabel: String = "确定",
         cancelLabel: String = "取消",
         probeID: String,
         onResult: @escaping @MainActor @Sendable (InputResult) -> Void) {
        self.title = title
        self.fields = fields
        self.validate = validate
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.probeID = probeID
        self.onResult = onResult
        self._values = State(initialValue: fields.map(\.initialText))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            headerRow

            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                ForEach(fields.indices, id: \.self) { idx in
                    fieldView(idx: idx)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
                    .transition(.opacity)
            }

            HStack(spacing: HVMTheme.space.sm) {
                Spacer()
                HVMUI.Button(cancelLabel, variant: .secondary,
                             probeID: "\(probeID).cancel") {
                    onResult(.cancelled)
                }
                HVMUI.Button(confirmLabel, variant: .primary,
                             disabled: !canSubmit,
                             probeID: "\(probeID).confirm") {
                    onResult(.submitted(values))
                }
            }
            .padding(.top, HVMTheme.space.xs)
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 440)
        .background(cardBackground)
        .animation(HVMTheme.motion.easeOut, value: validationError)
        .onAppear { runValidation() }
        .onChange(of: values) { _, _ in runValidation() }
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                         probeID: "\(probeID).close") {
                onResult(.cancelled)
            }
        }
    }

    @ViewBuilder
    private func fieldView(idx: Int) -> some View {
        let field = fields[idx]
        let binding = Binding(
            get: { values[idx] },
            set: { values[idx] = $0 }
        )
        if field.secure {
            HVMUI.SecureField(
                field.label,
                text: binding,
                placeholder: field.placeholder,
                icon: field.icon,
                autoFocus: idx == 0,   // 首个密码字段出现即聚焦
                probeID: "\(probeID).field.\(idx)",
                onSubmit: { submitIfValid() }
            )
        } else {
            HVMUI.TextField(
                field.label,
                text: binding,
                placeholder: field.placeholder,
                icon: field.icon,
                probeID: "\(probeID).field.\(idx)",
                onSubmit: { submitIfValid() }
            )
        }
    }

    private var canSubmit: Bool {
        validationError == nil
    }

    /// 回车提交 — 字段内按 Enter 触发, 校验通过才提交 (等同点主按钮)
    @MainActor
    private func submitIfValid() {
        if canSubmit { onResult(.submitted(values)) }
    }

    @MainActor
    private func runValidation() {
        guard let validate else {
            validationError = nil
            return
        }
        switch validate(values) {
        case .valid:
            validationError = nil
        case .invalid(let msg):
            validationError = msg
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
            .fill(HVMTheme.color.bgOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                    .stroke(HVMTheme.color.borderEmphasis,
                            lineWidth: HVMTheme.border.hairline)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
            .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
    }
}

}  // extension HVMUI 结束

// MARK: - DialogPresenter async API

/// Resume 协调器 — 跟 ConfirmDialog 同套思路, 单独一份避免泛型 across-file 实例化.
@MainActor
private final class InputResumeCoordinator {
    private var resumed = false
    private let cont: CheckedContinuation<HVMUI.InputResult, Never>

    init(cont: CheckedContinuation<HVMUI.InputResult, Never>) {
        self.cont = cont
    }

    func resumeIfNeeded(_ result: HVMUI.InputResult) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: result)
    }
}

extension HVMUI.DialogPresenter {
    /// 便利 async API — present input dialog + await 用户响应.
    /// 主按钮 → .submitted(values) (跟 fields 同长同序); 取消 / X / Esc / dismissAll → .cancelled.
    func input(title: String,
               fields: [HVMUI.InputField],
               validate: (@MainActor @Sendable ([String]) -> HVMUI.InputValidation)? = nil,
               confirmLabel: String = "确定",
               cancelLabel: String = "取消",
               probeID: String) async -> HVMUI.InputResult {
        await withCheckedContinuation { cont in
            let coordinator = InputResumeCoordinator(cont: cont)
            present(
                { handle in
                    HVMUI.InputDialog(
                        title: title,
                        fields: fields,
                        validate: validate,
                        confirmLabel: confirmLabel,
                        cancelLabel: cancelLabel,
                        probeID: probeID,
                        onResult: { result in
                            coordinator.resumeIfNeeded(result)
                            handle.close()
                        }
                    )
                },
                onDismiss: {
                    // Esc / dismissAll 不经过 onResult, 这里兜底 resume .cancelled
                    coordinator.resumeIfNeeded(.cancelled)
                }
            )
        }
    }
}

