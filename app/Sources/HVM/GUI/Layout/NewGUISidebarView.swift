// SidebarView.swift — 左栏 VM 列表 (业务页 #1, docs/v4/NEW_GUI_MAIN_LAYOUT.md M4).
//
// 行: 运行态圆点 + displayName + guestOS badge + 加密锁图标; 选中行 bgHover + 左侧
// accent 竖条. 点击选中, 右键 context menu (启停/删除). probeID `vmlist.row.item-<id>`.

#if NEW_GUI

import SwiftUI
import HVMControl
import HVMGuiProbe

struct NewGUISidebarView: View {
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if store.vms.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: HVMTheme.space.xs) {
                            ForEach(store.vms) { vm in
                                SidebarRow(vm: vm)
                            }
                        }
                        .padding(.vertical, HVMTheme.space.sm)
                        .padding(.horizontal, HVMTheme.space.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HVMTheme.color.bgBase)
    }

    /// 底部主操作: 全宽 "新建 VM" 主按钮 (刷新移到 statusbar 作工具图标, 见 MainLayoutView)
    private var footer: some View {
        HVMUI.Button("新建 VM", variant: .primary, icon: "plus",
                     fillWidth: true,
                     probeID: "sidebar.button.create") {
            Task { @MainActor in
                await dialog.alert(
                    level: .info,
                    title: "创建向导即将接入",
                    message: "VM 创建向导是后续子稿 (NEW_GUI_CREATE_VM.md). 当前请用 hvm-cli create 或老 GUI 创建.",
                    probeID: "sidebar.create.placeholder"
                )
            }
        }
        // 跟 VM 列表行同样的横向内缩 (LazyVStack .padding(.horizontal, .sm)), 让按钮左右边与 item 对齐
        .padding(.horizontal, HVMTheme.space.sm)
        .padding(.vertical, HVMTheme.space.sm)
    }

    private var emptyState: some View {
        VStack(spacing: HVMTheme.space.md) {
            Spacer()
            HVMUI.Icon("tray", size: .xl, color: .secondary)
            Text("还没有虚拟机")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HVMTheme.space.lg)
    }
}

/// 单行 VM 列表项
private struct SidebarRow: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter
    @State private var hovered = false

    private var isSelected: Bool { store.selectedID == vm.id }

    var body: some View {
        Button(action: select) {
            HStack(spacing: HVMTheme.space.sm) {
                // 运行态圆点
                Circle()
                    .fill(vm.runState == .running
                          ? HVMTheme.color.success
                          : HVMTheme.color.textTertiary)
                    .frame(width: 8, height: 8)

                Text(vm.displayName)
                    .font(HVMTheme.font.base)
                    .foregroundStyle(isSelected
                                     ? HVMTheme.color.textPrimary
                                     : HVMTheme.color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: HVMTheme.space.xs)

                if vm.isEncrypted {
                    HVMUI.Icon("lock.fill", size: .xs, color: .accent)
                }
                HVMUI.Badge(vm.guestOS.badgeLabel,
                            variant: vm.guestOS.badgeVariant,
                            size: .sm)
            }
            .padding(.horizontal, HVMTheme.space.sm)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                // 选中行左侧 2px accent 竖条
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(HVMTheme.color.accent)
                        .frame(width: 2, height: 18)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(HVMTheme.motion.easeOutFast, value: hovered)
        .hvmProbe(id: "vmlist.row.item-\(vm.id.uuidString)",
                  label: vm.displayName,
                  action: .button { store.selectedID = vm.id })
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if vm.runState == .stopped {
            Button("启动") { VMActions.start(vm, store: store, dialog: dialog) }
        } else {
            Button("停止") { store.stop(vm) }
            Button("强制停止") { store.kill(vm) }
        }
        Divider()
        Button("删除…", role: .destructive) {
            VMActions.confirmDelete(vm, store: store, dialog: dialog)
        }
        .disabled(vm.runState == .running)
    }

    private var rowBackground: Color {
        if isSelected { return HVMTheme.color.bgHover }
        if hovered { return HVMTheme.color.bgHover.opacity(0.5) }
        return Color.clear
    }

    private func select() { store.selectedID = vm.id }
}

#endif
