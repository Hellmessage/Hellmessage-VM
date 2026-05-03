// SnapshotCreateDialog.swift
// stopped 视图 Snapshots section "+ New Snapshot" 弹出的新建快照面板. 套 HVMModal.
// 必须 VM stopped; 内嵌"已有 snapshot"列表方便用户避免重名.

import SwiftUI
import HVMBundle
import HVMCore
import HVMStorage

struct SnapshotCreateDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var nameText: String = ""
    @State private var existing: [SnapshotManager.Info] = []

    var body: some View {
        HVMModal(
            title: "New Snapshot",
            icon: .info,
            width: 480,
            closeAction: { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                Text("为 \(item.displayName) 创建 APFS clonefile 快照 (磁盘 + config). 必须 VM 停止.")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    LabelText("Name")
                    HVMTextField("alphanumeric / - / _ / .", text: $nameText)
                }

                existingList
            }
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                Button("创建") { create() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var existingList: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("Existing snapshots (\(existing.count))")

            if existing.isEmpty {
                Text("(无)")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
                    .padding(.vertical, HVMSpace.xs)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(existing.enumerated()), id: \.element.name) { idx, info in
                            if idx != 0 {
                                Rectangle().fill(HVMColor.border).frame(height: 1)
                            }
                            HStack(spacing: HVMSpace.md) {
                                Text(info.name)
                                    .font(HVMFont.caption)
                                    .foregroundStyle(HVMColor.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(Self.dateFmt.string(from: info.createdAt))
                                    .font(HVMFont.small)
                                    .foregroundStyle(HVMColor.textTertiary)
                            }
                            .padding(.horizontal, HVMSpace.md)
                            .padding(.vertical, HVMSpace.buttonPadV7)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .hvmCard()
            }
        }
    }

    private static let dateFmt: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private func close() {
        model.snapshotCreateItem = nil
    }

    private func reload() {
        existing = SnapshotManager.list(bundleURL: item.bundleURL)
    }

    private func create() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            try SnapshotManager.create(bundleURL: item.bundleURL, name: trimmed)
            close()
        } catch {
            errors.present(error)
        }
    }
}
