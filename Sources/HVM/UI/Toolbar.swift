// Toolbar.swift
// 全宽顶部 toolbar. 跨左右栏, 保证主窗口视觉上"从上到下贯通"

import SwiftUI
import HVMCore

struct HVMToolbar: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        HStack(spacing: HVMSpace.md) {
            // 左: 应用品牌 + breadcrumb
            HStack(spacing: HVMSpace.sm) {
                Circle()
                    .fill(HVMColor.accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: HVMColor.accent.opacity(0.6), radius: 4)
                Text("HVM")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(HVMColor.textPrimary)
                if let item = model.selectedItem {
                    Text("/")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textTertiary)
                    Text(item.displayName)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 右: 全局操作
            Button(action: { model.refreshList() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("刷新 (Cmd+R)")
            .keyboardShortcut("r", modifiers: [.command])

            Button(action: { model.showCreateWizard = true }) {
                Text("+ NEW")
            }
            .buttonStyle(PillAccentButtonStyle())
            .help("新建 VM (Cmd+N)")
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, HVMSpace.lg)
        .frame(height: HVMBar.toolbarHeight)
        .background(HVMColor.bgBase)
        .overlay(
            Rectangle()
                .fill(HVMColor.border)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }
}
