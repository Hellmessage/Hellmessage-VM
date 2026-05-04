// EncryptionPasswordDialog.swift
// 加密 VM 启动 / 操作时的密码 prompt 弹窗.
// 设计稿 docs/v3/GUI_ENCRYPTION.md PR-11b.
//
// 用法:
//   EncryptionPasswordDialog(
//       displayName: "MyEncryptedVM",
//       prompt: "解锁加密 VM",
//       errorMessage: nil,
//       onSubmit: { pw in ... },
//       onCancel: { ... }
//   )
//
// 错误 (例如错密码) 走 errorMessage inline 显示, 不退 dialog 让用户重试.

import SwiftUI

struct EncryptionPasswordDialog: View {
    let displayName: String
    let prompt: String
    let bodyText: String
    /// 调用方传入 (例如 wrong_password 抛错后 inline 显示, 让用户重试)
    let errorMessage: String?
    /// 提交按钮文案 (默认"解锁"; encrypt/decrypt/rekey 各自可定制)
    let submitLabel: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password: String = ""

    init(displayName: String,
         prompt: String = "解锁加密 VM",
         body bodyArg: String? = nil,
         errorMessage: String? = nil,
         submitLabel: String = "解锁",
         onSubmit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.displayName = displayName
        self.prompt = prompt
        self.bodyText = bodyArg ?? "VM \"\(displayName)\" 已加密. 输入密码继续."
        self.errorMessage = errorMessage
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        HVMModal(
            title: prompt,
            icon: .info,
            width: 440,
            closeAction: { onCancel() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.md) {
                Text(bodyText)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HVMTextField("密码",
                              text: $password,
                              variant: .secure,
                              error: errorMessage)
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            HVMModalFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                Button(submitLabel) { onSubmit(password) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(password.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

}
