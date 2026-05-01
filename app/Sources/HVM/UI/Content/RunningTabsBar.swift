// RunningTabsBar.swift
// 主窗口右栏顶部的"运行中 VM" tab 栏. 类 Browser tab 隐喻:
//   - 显示当前所有 runState=running 的 VM
//   - 点 tab body → model.selectedID = id (DetailContainerView 现有 transition 自然切画面)
//   - 点 × → model.stop(id) (QEMU 后端自动走 IPC fallback)
//   - 0 个运行中 VM 时, 由 DetailContainerView 隐藏整条 (避免空 bar 占位)

import SwiftUI
import HVMBundle

struct RunningTabsBar: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HVMSpace.xs) {
                ForEach(runningItems) { item in
                    Tab(item: item,
                        isSelected: model.selectedID == item.id,
                        onSelect: { model.selectedID = item.id },
                        onClose: {
                            do { try model.stop(item.id) } catch { errors.present(error) }
                        })
                }
            }
            .padding(.horizontal, HVMSpace.sm)
            .padding(.vertical, HVMSpace.xs)
        }
        // maxHeight: .infinity + bg 在最外层: NSHostingView 高度由约束固定 38pt,
        // SwiftUI ScrollView 内容只有 ~32pt, 不填满则差额露出 DetailContainerView
        // 黑色背景 (一条窄横线, 随窗口宽度变化). 强制 ScrollView 填满 host.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HVMColor.bgSidebar)
    }

    private var runningItems: [AppModel.VMListItem] {
        model.list.filter { $0.runState == "running" }
    }
}

private struct Tab: View {
    let item: AppModel.VMListItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover: Bool = false
    @State private var closeHover: Bool = false

    var body: some View {
        HStack(spacing: HVMSpace.xs) {
            GuestBadge(os: item.guestOS, size: 18)
            Text(item.displayName)
                .font(HVMFont.caption)
                .foregroundStyle(isSelected ? HVMColor.textPrimary : HVMColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(closeHover ? HVMColor.danger : HVMColor.textTertiary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                            .fill(closeHover ? HVMColor.danger.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHover = $0 }
            .help("Stop this VM")
        }
        .padding(.horizontal, HVMSpace.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .fill(isSelected ? HVMColor.bgSelected
                                 : (hover ? HVMColor.bgHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(isSelected ? HVMColor.borderAccent : Color.clear, lineWidth: 1)
        )
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.1), value: hover)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
