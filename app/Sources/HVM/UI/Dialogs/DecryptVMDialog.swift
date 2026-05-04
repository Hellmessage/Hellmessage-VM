// DecryptVMDialog.swift
// 把加密 VM 转回明文 (冷迁移). 设计稿 docs/v3/GUI_ENCRYPTION.md PR-11e.

import SwiftUI
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu

struct DecryptVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    private enum Phase: Equatable {
        case form
        case running
        case done
    }

    @State private var phase: Phase = .form
    @State private var password: String = ""
    @State private var inlineError: String? = nil
    @State private var progressLines: [String] = []

    var body: some View {
        HVMModal(
            title: "解密 VM (转明文)",
            icon: .warning,
            width: 520,
            closeAction: phase == .running ? nil : { close() }
        ) {
            switch phase {
            case .form:    formView
            case .running: runningView
            case .done:    doneView
            }
        } footer: {
            HVMModalFooter {
                switch phase {
                case .form:
                    Button("取消") { close() }
                        .buttonStyle(GhostButtonStyle())
                    Button("解密") { startDecrypt() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(password.isEmpty)
                case .running:
                    Button("解密中…") {}
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(true)
                case .done:
                    Button("完成") { close() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }

    @ViewBuilder
    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            Text("即将把 \(item.displayName) 转为明文 VM:")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textPrimary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                Text("• disks / nvram / config 全部变明文")
                Text("• 数据可被任何能读 bundle 文件的进程查看 (host 用户隔离仍生效)")
                Text("• 需要 ≈ 主盘 + 数据盘大小总和的临时空间")
            }
            .font(HVMFont.small)
            .foregroundStyle(HVMColor.textSecondary)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("Password")
                HVMTextField("当前密码", text: $password, variant: .secure)
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
                Text("解密中, 请勿关闭窗口…").font(HVMFont.body)
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
    private var doneView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            HStack(spacing: HVMSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HVMColor.statusRunning)
                Text("\(item.displayName) 已转明文").font(HVMFont.body)
            }
            Text("下次启动无需密码")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textSecondary)
        }
    }

    private func close() {
        if phase == .running { return }
        model.decryptItem = nil
    }

    private func startDecrypt() {
        inlineError = nil
        phase = .running
        let pw = password
        let bundleURL = item.bundleURL

        Task.detached {
            let result: Result<DecryptVMOperation.Result, Error>
            do {
                let qemuImg = try QemuPaths.qemuImgBinary()
                let r = try DecryptVMOperation.decrypt(
                    bundleURL: bundleURL,
                    password: pw,
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
                case .success:
                    self.model.refreshList()
                    self.phase = .done
                case .failure(let err):
                    self.phase = .form
                    self.inlineError = err.localizedDescription
                }
            }
        }
    }
}
