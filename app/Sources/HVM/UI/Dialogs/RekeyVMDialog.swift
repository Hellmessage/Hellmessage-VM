// RekeyVMDialog.swift
// 改密加密 VM. 设计稿 docs/v3/GUI_ENCRYPTION.md PR-11e.
// rekey 重置 TPM (swtpm 0.10 无 rewrap; 详 docs/v3/ENCRYPTION.md v2.4 PR-10b).

import SwiftUI
import HVMBundle
import HVMCore
import HVMEncryption
import HVMGuiProbe
import HVMQemu

struct RekeyVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    private enum Phase: Equatable {
        case form
        case running
        case done(tpmReset: Bool)
    }

    @State private var phase: Phase = .form
    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var newPasswordConfirm: String = ""
    @State private var inlineError: String? = nil
    @State private var progressLines: [String] = []

    var body: some View {
        HVMModal(
            title: "改密 (Rekey)",
            icon: .warning,
            width: 520,
            closeAction: phase == .running ? nil : { close() }
        ) {
            switch phase {
            case .form:               formView
            case .running:            runningView
            case .done(let tpmReset): doneView(tpmReset: tpmReset)
            }
        } footer: {
            HVMModalFooter {
                switch phase {
                case .form:
                    Button("取消") { close() }
                        .buttonStyle(GhostButtonStyle())
                        .hvmProbe(id: "dialog.rekeyVM.button.cancel", label: "Cancel",
                                   action: .button { close() })
                    Button("改密") { startRekey() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSubmit)
                        .hvmProbe(id: "dialog.rekeyVM.button.rekey", label: "Rekey",
                                   action: .button { startRekey() })
                case .running:
                    Button("改密中…") {}
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(true)
                case .done:
                    Button("完成") { close() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .hvmProbe(id: "dialog.rekeyVM.button.done", label: "Done",
                                   action: .button { close() })
                }
            }
        }
    }

    @ViewBuilder
    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            Text("改密 \(item.displayName):")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textPrimary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                Text("• LUKS qcow2 keyslot 重写 (毫秒级, 不重密 DEK)")
                Text("• config.yaml.enc 用新 key 重 AES-GCM seal")
                Text("• routing JSON 写新 salt (跨机器需用新密码)")
                if item.guestOS == .windows {
                    Text("• ⚠ TPM 状态会重置 (swtpm 0.10 无 rewrap)")
                        .foregroundStyle(HVMColor.danger)
                    Text("  → 后果: BitLocker recovery key / TPM-sealed secrets 全丢")
                        .font(HVMFont.tiny)
                        .foregroundStyle(HVMColor.textTertiary)
                    Text("  → 改密前请确认你已 backup guest 内 BitLocker recovery key")
                        .font(HVMFont.tiny)
                        .foregroundStyle(HVMColor.textTertiary)
                }
            }
            .font(HVMFont.small)
            .foregroundStyle(HVMColor.textSecondary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("Old Password")
                HVMTextField("当前密码", text: $oldPassword, variant: .secure)
                    .hvmProbe(id: "dialog.rekeyVM.input.oldPassword", label: "Old Password",
                               action: .textField(getter: { oldPassword },
                                                   setter: { oldPassword = $0 }))
            }
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("New Password")
                HVMTextField("≥ 4 字符", text: $newPassword, variant: .secure)
                    .hvmProbe(id: "dialog.rekeyVM.input.newPassword", label: "New Password",
                               action: .textField(getter: { newPassword },
                                                   setter: { newPassword = $0 }))
            }
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("Confirm New")
                HVMTextField("再次输入新密码", text: $newPasswordConfirm, variant: .secure,
                              error: passwordError)
                    .hvmProbe(id: "dialog.rekeyVM.input.newPasswordConfirm", label: "Confirm New",
                               action: .textField(getter: { newPasswordConfirm },
                                                   setter: { newPasswordConfirm = $0 }))
            }

            if let inlineError {
                Text(inlineError)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.danger)
            }
        }
    }

    @ViewBuilder
    private var runningView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            HStack(spacing: HVMSpace.sm) {
                ProgressView().controlSize(.small)
                Text("改密中, 请勿关闭窗口 (中断会让两个密码都解不开)…")
                    .font(HVMFont.body)
            }
            if !progressLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(progressLines.indices, id: \.self) { i in
                            Text(progressLines[i])
                                .font(HVMFont.monoSmall)
                                .foregroundStyle(HVMColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(HVMSpace.sm)
                .hvmCard()
            }
        }
    }

    @ViewBuilder
    private func doneView(tpmReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            HStack(spacing: HVMSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HVMColor.statusRunning)
                Text("\(item.displayName) 已改密").font(HVMFont.body)
            }
            if tpmReset {
                Text("⚠ TPM 已重置")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.danger)
            }
            Text("下次启动用新密码")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textSecondary)
        }
    }

    private var canSubmit: Bool {
        !oldPassword.isEmpty &&
            !newPassword.isEmpty &&
            newPassword == newPasswordConfirm &&
            newPassword.count >= 4 &&
            newPassword != oldPassword
    }

    private var passwordError: String? {
        if newPasswordConfirm.isEmpty { return nil }
        if newPassword != newPasswordConfirm { return "两次输入不一致" }
        if newPassword.count < 4 { return "新密码至少 4 字符" }
        if !oldPassword.isEmpty && newPassword == oldPassword { return "新密码必须 ≠ 原密码" }
        return nil
    }

    private func close() {
        if phase == .running { return }
        model.rekeyItem = nil
    }

    private func startRekey() {
        inlineError = nil
        phase = .running
        let oldPw = oldPassword
        let newPw = newPassword
        let bundleURL = item.bundleURL

        Task.detached {
            let result: Result<RekeyVMOperation.Result, Error>
            do {
                let qemuImg = try QemuPaths.qemuImgBinary()
                let r = try RekeyVMOperation.rekey(
                    bundleURL: bundleURL,
                    oldPassword: oldPw,
                    newPassword: newPw,
                    qemuImg: qemuImg,
                    progressLog: { msg in
                        Task { @MainActor in self.progressLines.append(msg) }
                    }
                )
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.model.refreshList()
                    self.phase = .done(tpmReset: r.tpmReset)
                case .failure(let err):
                    self.phase = .form
                    self.inlineError = err.localizedDescription
                }
            }
        }
    }
}
