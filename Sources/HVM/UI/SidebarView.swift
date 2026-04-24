// SidebarView.swift
// 左栏: 只放 "VMS" section + VM 列表. 顶部 toolbar / 底部 status bar 已搬走, 此处保持极简

import SwiftUI
import HVMBundle
import HVMCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .background(HVMColor.bgSidebar)
    }

    // MARK: - section header

    private var header: some View {
        HStack(spacing: 6) {
            Text(">")
                .font(HVMFont.bodyBold)
                .foregroundStyle(HVMColor.accent)
            LabelText("VMs (\(model.list.count))", color: HVMColor.textSecondary)
            Spacer()
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.md)
        .padding(.bottom, HVMSpace.sm)
    }

    // MARK: - list

    @ViewBuilder
    private var list: some View {
        if model.list.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.list) { item in
                        Row(item: item,
                            isSelected: model.selectedID == item.id,
                            isRunning: model.sessions[item.id] != nil || item.runState == "running")
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = item.id }
                    }
                }
                .padding(.horizontal, HVMSpace.sm)
                .padding(.bottom, HVMSpace.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            Text("// no vms yet")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
            Text("click + NEW to create")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单行

private struct Row: View {
    let item: AppModel.VMListItem
    let isSelected: Bool
    let isRunning: Bool
    @State private var hover: Bool = false

    var body: some View {
        HStack(spacing: HVMSpace.sm) {
            // 左侧 accent 竖条 (选中时)
            Rectangle()
                .fill(isSelected ? HVMColor.accent : Color.clear)
                .frame(width: 2)

            // 状态 sigil
            Group {
                if isRunning {
                    PulseDot(color: HVMColor.statusRunning, size: 5)
                        .frame(width: 14, height: 14)
                } else {
                    Text("○")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textTertiary)
                        .frame(width: 14, height: 14)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HVMColor.textPrimary)
                    .lineLimit(1)
                Text(isRunning ? "running" : "stopped")
                    .font(HVMFont.small)
                    .foregroundStyle(isRunning ? HVMColor.statusRunning
                                               : HVMColor.textTertiary)
            }

            Spacer(minLength: 0)

            // 右侧 guest 标识 (小号, 不抢焦点)
            Text(GuestVisual.style(for: item.guestOS).label)
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(.leading, HVMSpace.xs)
        .padding(.trailing, HVMSpace.md)
        .padding(.vertical, HVMSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                .fill(isSelected ? HVMColor.bgSelected
                                 : (hover ? HVMColor.bgHover : Color.clear))
        )
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.1), value: hover)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
