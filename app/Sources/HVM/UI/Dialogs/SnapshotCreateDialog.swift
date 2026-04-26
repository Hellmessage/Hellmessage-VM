// SnapshotCreateDialog.swift
// stopped 视图 Snapshots section "+ NEW" 按钮弹出的新建快照面板.
// 严格按 docs/GUI.md 弹窗约束: X 关 / 禁止遮罩 / 禁止 Esc / 禁止 NSAlert.
//
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli snapshot create).
// 内嵌一个只读的"已有 snapshot"列表, 方便用户避免重名.

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
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶栏
                HStack(spacing: HVMSpace.md) {
                    Text("●")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.accent)
                    Text("新建快照".uppercased())
                        .font(HVMFont.label)
                        .tracking(1.6)
                        .foregroundStyle(HVMColor.textPrimary)
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("关闭 (Cmd+W)")
                    .keyboardShortcut("w", modifiers: [.command])
                }
                .padding(.horizontal, HVMSpace.lg)
                .padding(.vertical, HVMSpace.md)

                Divider().background(HVMColor.border)

                VStack(alignment: .leading, spacing: HVMSpace.lg) {
                    Text("为 \(item.displayName) 创建一个 APFS clonefile 快照 (磁盘 + config). 必须 VM 停止.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)

                    HStack(spacing: HVMSpace.md) {
                        Text("NAME")
                            .font(HVMFont.label)
                            .tracking(1.5)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(width: 80, alignment: .leading)
                        TextField("alphanumeric / - / _ / .", text: $nameText)
                            .textFieldStyle(.roundedBorder)
                            .font(HVMFont.body)
                            .frame(maxWidth: .infinity)
                    }

                    existingList

                    HStack(spacing: HVMSpace.md) {
                        Spacer()
                        Button("取消") { close() }
                            .buttonStyle(GhostButtonStyle())
                        Button("创建") { create() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(HVMSpace.lg)
            }
            .frame(width: 460)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous)
                    .stroke(HVMColor.borderStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
        }
        .transition(.opacity)
        .onAppear { reload() }
    }

    @ViewBuilder
    private var existingList: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            Text("已有 \(existing.count) 个快照".uppercased())
                .font(HVMFont.label)
                .tracking(1.5)
                .foregroundStyle(HVMColor.textTertiary)

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
                            .padding(.vertical, 7)
                        }
                    }
                }
                .frame(maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgBase))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
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
