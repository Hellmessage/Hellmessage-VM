// SidebarView.swift
// 左栏: VM 列表卡片化. 顶部 section header (Virtual Machines + 计数), 列表项 = guest icon + 名 + 状态.

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HVMColor.bgSidebar)
    }

    // MARK: - section header

    private var header: some View {
        HStack(spacing: HVMSpace.sm) {
            Text("Virtual Machines")
                .font(HVMFont.label)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()
            Text("\(model.list.count)")
                .font(HVMFont.small.weight(.semibold))
                .foregroundStyle(HVMColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.lg)
        .padding(.bottom, HVMSpace.sm)
    }

    // MARK: - list

    @ViewBuilder
    private var list: some View {
        if model.list.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            Text("No VMs yet")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
            Button(action: { model.showCreateWizard = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Create VM")
                }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单卡

private struct Row: View {
    let item: AppModel.VMListItem
    let isSelected: Bool
    let isRunning: Bool
    @State private var hover: Bool = false

    var body: some View {
        HStack(spacing: HVMSpace.sm) {
            GuestBadge(os: item.guestOS, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    if isRunning {
                        Circle()
                            .fill(HVMColor.statusRunning)
                            .frame(width: 6, height: 6)
                        Text("Running")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.statusRunning)
                    } else {
                        Circle()
                            .fill(HVMColor.statusStopped.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text("Stopped")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                    Text("·")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                    Text(GuestVisual.style(for: item.guestOS).label)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HVMSpace.sm)
        .padding(.vertical, HVMSpace.sm)
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
        .animation(.easeOut(duration: 0.1), value: hover)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
