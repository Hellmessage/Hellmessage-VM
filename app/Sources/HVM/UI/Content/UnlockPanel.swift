// UnlockPanel.swift
// 加密 VM 在 sidebar 选中后, 详情区显示的"配置查看解锁"面板.
// 设计目标: 用户点 sidebar 加密 VM → 右栏直接出密码框, 输完密码 → 详情页正常渲染.
//
// 跟 EncryptionPasswordDialog 的区别:
//   - EncryptionPasswordDialog 是 HVMModal (黑遮罩 + 居中卡片), 启动 VM 时弹
//   - UnlockPanel 是详情区内嵌, 仅解开 config.yaml.enc 看配置 (不启动 VM, 不留 KEK)
//
// 安全:
//   - 密码不打 log, 不写 stdout/stderr
//   - 解锁结果存 AppModel.unlockedConfigs[vmId] (内存) — 不落盘, 不带 master KEK
//   - 进程退出 / 用户主动锁定 → 自然清

import SwiftUI
import HVMCore
import HVMGuiProbe

struct UnlockPanel: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var password: String = ""
    @State private var inlineError: String? = nil
    @State private var unlocking: Bool = false

    var body: some View {
        VStack(spacing: HVMSpace.lg) {
            Spacer(minLength: HVMSpace.xl)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(HVMColor.bgCard)
                    .frame(width: 88, height: 88)
                Image(systemName: "lock.fill")
                    .font(HVMFont.display)
                    .foregroundStyle(HVMColor.accent)
            }

            VStack(spacing: HVMSpace.sm) {
                Text("\(item.displayName) 已加密")
                    .font(HVMFont.title)
                    .foregroundStyle(HVMColor.textPrimary)
                Text("输入密码查看完整配置. 启动 VM 时仍需重新输入密码.")
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: HVMSpace.sm) {
                HVMTextField("密码",
                              text: $password,
                              variant: .secure,
                              error: inlineError)
                    .hvmProbe(id: "panel.unlockConfig.input.password",
                               label: "Password",
                               action: .textField(getter: { password },
                                                   setter: { password = $0 }))
                    .onSubmit { submit() }
                    .disabled(unlocking)

                Button(action: { submit() }) {
                    HStack(spacing: HVMSpace.xs) {
                        if unlocking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "lock.open.fill")
                                .font(HVMFont.captionBold)
                        }
                        Text(unlocking ? "解锁中…" : "解锁")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(password.isEmpty || unlocking)
                .keyboardShortcut(.return, modifiers: [])
                .hvmProbe(id: "panel.unlockConfig.button.submit",
                           label: "Unlock",
                           action: .button { submit() })
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HVMSpace.xl)
    }

    private func submit() {
        guard !password.isEmpty, !unlocking else { return }
        let pw = password
        let captured = item
        inlineError = nil
        unlocking = true

        Task { @MainActor in
            do {
                try await model.unlockEncryptedConfigForView(item: captured, password: pw)
                // 成功: 不清密码状态 — 此 view 会因 list 刷新换成详情页, 自然销毁
            } catch {
                unlocking = false
                inlineError = friendlyMessage(for: error)
            }
        }
    }

    /// 把常见错误映射成简短中文. 错密码单独处理 — UnlockPanel 主要 use case.
    private func friendlyMessage(for error: Error) -> String {
        if case HVMError.encryption(.wrongPassword) = error {
            return "密码错误"
        }
        return (error as? HVMError)?.localizedDescription ?? error.localizedDescription
    }
}
