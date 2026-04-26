// Toolbar.swift
// 全宽顶部工具栏. 左侧 brand + 当前 VM 名; 右侧刷新 / 新建.

import SwiftUI
import HVMCore

struct HVMToolbar: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        HStack(spacing: HVMSpace.md) {
            // 左: 品牌 + breadcrumb
            HStack(spacing: HVMSpace.sm) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HVMColor.accent)
                Text("HVM")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HVMColor.textPrimary)
                if let item = model.selectedItem {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(HVMColor.textTertiary)
                    Text(item.displayName)
                        .font(HVMFont.body)
                        .foregroundStyle(HVMColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: { model.refreshList() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("刷新 (Cmd+R)")
            .keyboardShortcut("r", modifiers: [.command])

            Button(action: { model.showCreateWizard = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New VM")
                }
            }
            .buttonStyle(PillAccentButtonStyle())
            .help("新建 VM (Cmd+N)")
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, HVMSpace.lg)
        .frame(height: HVMBar.toolbarHeight)
        .background(HVMColor.bgSidebar)
    }
}
