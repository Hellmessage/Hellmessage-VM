// EncryptVMDialog.swift
// 把现有明文 QEMU VM 转加密 (冷迁移). 设计稿 docs/v3/GUI_ENCRYPTION.md PR-11e.
//
// 三态 phase:
//   - .form    输 password + confirm + warning 文本 + Confirm/Cancel
//   - .running spinner + 进度日志 行 (closeAction = nil 不可关)
//   - .done    ✔ 完成 + 提示 "下次启动用新密码" + Done

import SwiftUI
import HVMBundle
import HVMCore
import HVMEncryption
import HVMGuiProbe
import HVMQemu

struct EncryptVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    private enum Phase: Equatable {
        case form
        case running
        case done(tpmReset: Bool)
    }

    @State private var phase: Phase = .form
    @State private var password: String = ""
    @State private var passwordConfirm: String = ""
    @State private var inlineError: String? = nil
    @State private var progressLines: [String] = []

    var body: some View {
        HVMModal(
            title: "加密 VM",
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
                        .hvmProbe(id: "dialog.encryptVM.button.cancel", label: "Cancel",
                                   action: .button { close() })
                    Button("加密") { startEncrypt() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(password.isEmpty || password != passwordConfirm || password.count < 4)
                        .hvmProbe(id: "dialog.encryptVM.button.encrypt", label: "Encrypt",
                                   action: .button { startEncrypt() })
                case .running:
                    Button("加密中…") {}
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(true)
                case .done:
                    Button("完成") { close() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .hvmProbe(id: "dialog.encryptVM.button.done", label: "Done",
                                   action: .button { close() })
                }
            }
        }
    }

    @ViewBuilder
    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            Text("即将把 \(item.displayName) 转为加密 VM:")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textPrimary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                Text("• 主盘 / 数据盘: 转 LUKS qcow2 (AES-256-XTS)")
                Text("• OVMF VARS: 转 LUKS qcow2 (Win 才有, BootOrder 保留)")
                Text("• config.yaml: AES-GCM in-place 加密")
                if item.guestOS == .windows {
                    Text("• ⚠ TPM 状态将重置: BitLocker / SecureBoot 信任根丢失, 首启 Win 重新 attest")
                        .foregroundStyle(HVMColor.danger)
                }
                Text("• 临时空间需求: ≈ 主盘 + 数据盘大小总和 (转换期间)")
                Text("• 跨机器 portable: cp 整 .hvmz 到另一台 Mac, 同密码可启动")
            }
            .font(HVMFont.small)
            .foregroundStyle(HVMColor.textSecondary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("Password")
                HVMTextField("≥ 4 字符", text: $password, variant: .secure)
                    .hvmProbe(id: "dialog.encryptVM.input.password", label: "Password",
                               action: .textField(getter: { password },
                                                   setter: { password = $0 }))
            }
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("Confirm")
                HVMTextField("再次输入", text: $passwordConfirm, variant: .secure,
                              error: passwordError)
                    .hvmProbe(id: "dialog.encryptVM.input.passwordConfirm", label: "Confirm",
                               action: .textField(getter: { passwordConfirm },
                                                   setter: { passwordConfirm = $0 }))
            }

            Text("⚠ 忘密不可恢复. 操作不可撤销.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.danger)

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
                Text("加密中, 请勿关闭窗口…").font(HVMFont.body)
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
                Text("\(item.displayName) 已加密").font(HVMFont.body)
            }
            if tpmReset {
                Text("⚠ TPM 已重置 — Win VM 启动会重新 attest")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.danger)
            }
            Text("下次启动会 prompt 密码输入")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textSecondary)
        }
    }

    private var passwordError: String? {
        if passwordConfirm.isEmpty { return nil }
        if password != passwordConfirm { return "两次输入不一致" }
        if password.count < 4 { return "密码至少 4 字符" }
        return nil
    }

    private func close() {
        if phase == .running { return }    // 不可中断
        model.encryptItem = nil
    }

    private func startEncrypt() {
        inlineError = nil
        phase = .running
        let pw = password
        let bundleURL = item.bundleURL
        let isWin = item.guestOS == .windows

        Task.detached {
            let result: Result<EncryptVMOperation.Result, Error>
            do {
                let qemuImg = try QemuPaths.qemuImgBinary()
                var template: URL? = nil
                if isWin {
                    let qemuRoot = try QemuPaths.resolveRoot()
                    template = qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-vars.fd")
                }
                let r = try EncryptVMOperation.encrypt(
                    bundleURL: bundleURL,
                    password: pw,
                    qemuImg: qemuImg,
                    ovmfVarsTemplate: template,
                    progressLog: { msg in
                        Task { @MainActor in
                            self.progressLines.append(msg)
                        }
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
