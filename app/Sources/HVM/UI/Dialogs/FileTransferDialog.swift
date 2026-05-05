// FileTransferDialog.swift
// host ↔ guest 单文件传输弹窗 (qemu-guest-agent guest-file-* API).
//
// 设计稿: docs/v3/FILE_COPY.md PR-D.
// 状态机: form → running → done / error → 关闭.
// 不支持取消 (D5: v1 cancel 按钮只 close modal, 后台 chunk 跑完才退. 不可中断期间隐藏 X).

import SwiftUI
import HVMBundle
import HVMCore
import HVMGuiProbe

struct FileTransferDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let request: AppModel.FileTransferRequest

    @State private var remotePath: String = ""
    @State private var phase: Phase = .form
    @State private var inlineError: String? = nil
    @State private var resultBytes: Int64 = 0
    @State private var resultDurationMs: Int64 = 0
    @State private var transferTask: Task<Void, Never>? = nil

    private enum Phase { case form, running, done }

    private var isPush: Bool { request.direction == .push }
    private var titleText: String { isPush ? "传文件到 VM" : "从 VM 取文件" }
    private var hostLabel: String { isPush ? "host 源文件" : "host 保存到" }
    private var remoteLabel: String { isPush ? "guest 目标路径" : "guest 源路径" }
    private var remoteHint: String { isPush ? "(覆盖目标)" : "" }

    var body: some View {
        HVMModal(
            title: titleText,
            icon: .info,
            width: 560,
            // 传输中不可关 (chunk 循环 best-effort 跑完); 其它阶段允许 X
            closeAction: phase == .running ? nil : { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                hostLine
                remoteLine
                statusBlock
            }
        } footer: {
            HVMModalFooter {
                footerButtons
            }
        }
        .onAppear {
            remotePath = request.suggestedRemotePath
        }
        .onDisappear {
            transferTask?.cancel()
        }
    }

    private var hostLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText(hostLabel)
            Text(request.hostURL.path)
                .font(HVMFont.mono)
                .foregroundStyle(HVMColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var remoteLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("\(remoteLabel) \(remoteHint)")
            HVMTextField(
                isPush ? "C:\\path\\file 或 /tmp/file" : "guest 内绝对路径",
                text: $remotePath
            )
            .disabled(phase != .form)
            .hvmProbe(id: "dialog.fileTransfer.input.remotePath",
                      label: remoteLabel,
                      action: .textField(getter: { remotePath },
                                         setter: { remotePath = $0 }))
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch phase {
        case .form:
            if let msg = inlineError {
                Text(msg)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(hintText)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .running:
            HStack(spacing: HVMSpace.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("传输中... (本通路 1-10 MB/s; 大文件请耐心等待)")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                Text("✓ 传输完成")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textPrimary)
                Text(doneSummary)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
            }
        }
    }

    private var hintText: String {
        if isPush {
            return "通过 qemu-guest-agent 写入 guest. 中断会留半成品 dst (v1 限制). VM 必须在跑且 qemu-ga 服务已启动."
        } else {
            return "从 guest 读出来. 本地走 .hvm-tmp + 原子 rename, 中断不留残留. VM 必须在跑且 qemu-ga 服务已启动."
        }
    }

    private var doneSummary: String {
        let mb = Double(resultBytes) / (1024.0 * 1024.0)
        let secs = Double(resultDurationMs) / 1000.0
        let mbps = secs > 0.001 ? mb / secs : 0
        return String(format: "%.2f MiB · %.2fs · %.2f MB/s", mb, secs, mbps)
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch phase {
        case .form:
            Button("取消") { close() }
                .buttonStyle(GhostButtonStyle())
                .hvmProbe(id: "dialog.fileTransfer.button.cancel",
                          label: "取消",
                          action: .button { close() })
            Button(isPush ? "开始传输" : "开始拉取") { start() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(remotePathTrim.isEmpty)
                .hvmProbe(id: "dialog.fileTransfer.button.start",
                          label: "开始",
                          action: .button { start() })
        case .running:
            // 不可中断 — X 已隐藏, footer 留空 (footer Body required, 用 EmptyView 类似)
            Text("")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        case .done:
            Button("关闭") { close() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
                .hvmProbe(id: "dialog.fileTransfer.button.close",
                          label: "关闭",
                          action: .button { close() })
        }
    }

    private var remotePathTrim: String {
        remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func close() {
        transferTask?.cancel()
        model.fileTransferRequest = nil
    }

    private func start() {
        let path = remotePathTrim
        guard !path.isEmpty else { return }
        inlineError = nil
        phase = .running
        transferTask = Task { @MainActor in
            do {
                let result = try await model.runFileTransfer(
                    item: request.item,
                    direction: request.direction,
                    hostURL: request.hostURL,
                    remotePath: path
                )
                resultBytes = result.bytes
                resultDurationMs = result.durationMs
                phase = .done
            } catch {
                inlineError = "\(error.localizedDescription)"
                phase = .form
            }
        }
    }
}
