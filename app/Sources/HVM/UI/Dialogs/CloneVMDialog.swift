// CloneVMDialog.swift
// stopped 视图 actionRow "Clone" 按钮弹出的整 VM 克隆面板. 套 HVMModal.
// 必须 VM stopped (CloneManager 内部抢源 .edit lock; 行动按钮也只在 stopped 视图出现).
//
// 三态 phase:
//   - .form     输入新 VM 名 + 高级选项 (保留 MAC / 含快照), Cancel / Clone 按钮
//   - .running  spinner + "克隆中…", closeAction=nil 不可中断
//   - .done     ✔ 摘要 + Reveal in Finder / Done 按钮
// 失败 → 切回 .form + 内联错误提示, 用户可改名重试.

import SwiftUI
import AppKit
import HVMBundle
import HVMCore
import HVMStorage

struct CloneVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    private enum Phase: Equatable {
        case form
        case running
        case done(targetPath: String, newIDDescription: String, renamedDataDisks: [String: String])
    }

    @State private var phase: Phase = .form
    @State private var nameText: String = ""
    @State private var keepMac: Bool = false
    @State private var includeSnapshots: Bool = false
    @State private var inlineError: String? = nil

    var body: some View {
        HVMModal(
            title: "Clone Virtual Machine",
            icon: .info,
            width: 520,
            closeAction: phase == .running ? nil : { close() }
        ) {
            switch phase {
            case .form:    formView
            case .running: runningView
            case .done(let path, let newID, let renamed):
                doneView(path: path, newID: newID, renamed: renamed)
            }
        } footer: {
            HVMModalFooter {
                switch phase {
                case .form:
                    Button("取消") { close() }
                        .buttonStyle(GhostButtonStyle())
                    Button("克隆") { startClone() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
                case .running:
                    Button("克隆中…") {}
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(true)
                case .done(let path, _, _):
                    Button("Reveal") {
                        revealInFinder(path: path)
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("完成") { close() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
        .onAppear { initialName() }
    }

    // MARK: - 各 phase 内容

    @ViewBuilder
    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            Text("从 \(item.displayName) 克隆出一台独立 VM. 走 APFS clonefile, 几乎零空间; 完成后两台互不影响.")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("新 VM 名称")
                HVMTextField("例: \(item.displayName) 副本", text: $nameText)
            }

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("目标位置")
                Text(item.bundleURL.deletingLastPathComponent().path)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: HVMSpace.sm) {
                HVMToggle(
                    "保留所有 NIC MAC",
                    isOn: $keepMac,
                    help: "默认重生 MAC. 保留时同 LAN 上同时跑两台会冲突, 用户自负"
                )
                HVMToggle(
                    "包含快照",
                    isOn: $includeSnapshots,
                    help: "默认不带 snapshots/, 克隆是另起新 VM. 勾选后整目录复制 (仍走 COW)"
                )
            }

            if let inlineError {
                HStack(alignment: .top, spacing: HVMSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(HVMColor.statusError)
                        .padding(.top, 2)
                    Text(inlineError)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(HVMSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HVMColor.statusError.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                        .stroke(HVMColor.statusError.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var runningView: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            HStack(spacing: HVMSpace.md) {
                ProgressView()
                    .controlSize(.small)
                Text("克隆 \(item.displayName) → \(nameText)")
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
                Spacer()
            }
            Text("APFS clonefile + 重生 UUID / MAC / machine-identifier 中, 不可中断. 大盘几秒, 通常瞬间完成.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func doneView(path: String, newID: String, renamed: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            HStack(spacing: HVMSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(HVMColor.statusRunning)
                Text("克隆完成")
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textPrimary)
            }

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("目标")
                Text(path)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                LabelText("新 ID")
                Text(newID)
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(HVMColor.textSecondary)
            }

            if !renamed.isEmpty {
                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    LabelText("数据盘 uuid8 重生")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(renamed.sorted(by: { $0.key < $1.key }), id: \.key) { (old, new) in
                            Text("\(old) → \(new)")
                                .font(HVMFont.monoSmall)
                                .foregroundStyle(HVMColor.textTertiary)
                        }
                    }
                }
            }

            if item.guestOS == .windows {
                Text("⚠️ 克隆 Windows VM 后可能需要重新激活 (TPM 状态保留, 但机器身份变了).")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.statusPaused)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 行为

    private func close() {
        guard phase != .running else { return }
        model.cloneItem = nil
    }

    private func initialName() {
        let parent = item.bundleURL.deletingLastPathComponent()
        let base = "\(item.displayName) 副本"
        if !targetExists(name: base, in: parent) {
            nameText = base
        } else {
            for i in 2...100 {
                let candidate = "\(base) \(i)"
                if !targetExists(name: candidate, in: parent) {
                    nameText = candidate
                    return
                }
            }
            nameText = base
        }
    }

    private func targetExists(name: String, in dir: URL) -> Bool {
        let url = dir.appendingPathComponent("\(name).hvmz", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func startClone() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        let opts = CloneManager.Options(
            newDisplayName: trimmed,
            targetParentDir: nil,             // 默认 = 源父目录
            keepMACAddresses: keepMac,
            includeSnapshots: includeSnapshots
        )
        let source = item.bundleURL
        inlineError = nil
        phase = .running

        // CloneManager.clone 是同步阻塞 (clonefile + 文件 IO), 在后台 Task 跑避免阻 UI.
        // 完成后回主线程切 phase. 失败 → 切回 .form + inline 错误.
        Task.detached {
            let result: Result<CloneManager.Result, Error>
            do {
                let r = try CloneManager.clone(sourceBundle: source, options: opts)
                result = .success(r)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success(let r):
                    self.phase = .done(
                        targetPath: r.targetBundle.path,
                        newIDDescription: r.newID.uuidString,
                        renamedDataDisks: r.renamedDataDiskUUID8s
                    )
                    // 触发主列表刷新, 让新 VM 立刻出现
                    self.model.refreshList()
                case .failure(let err):
                    self.phase = .form
                    self.inlineError = Self.formatError(err)
                }
            }
        }
    }

    private static func formatError(_ err: Error) -> String {
        if let hvm = err as? HVMError {
            let uf = hvm.userFacing
            if let hint = uf.hint, !hint.isEmpty {
                return "\(uf.message). \(hint)"
            }
            return uf.message
        }
        return "\(err)"
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
