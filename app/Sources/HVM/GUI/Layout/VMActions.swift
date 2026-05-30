// VMActions.swift — sidebar context menu + detail 按钮共用的 VM 动作 (含 dialog 流程).
// docs/v4/NEW_GUI_MAIN_LAYOUT.md M4/M5.
//
// 启动加密 VM / 删除 需要弹 dialog (密码 / 确认), store 本身不弹 (保持纯数据); 这里把
// dialog 流程 + store 调用粘起来, 供 sidebar 右键菜单与 detail 按钮复用, 不重复两份.

#if NEW_GUI

import SwiftUI
import HVMControl

@MainActor
enum VMActions {
    /// 启动. 明文直启; 加密 VM 已解锁则复用缓存密码, 否则弹密码 InputDialog.
    static func start(_ vm: VMSummary,
                      store: NewGUIStore,
                      dialog: HVMUI.DialogPresenter) {
        guard vm.isEncrypted else {
            store.start(vm, password: nil)
            return
        }
        // 已解锁: 复用缓存密码, 不再弹
        if let pw = store.unlockedPassword(vm.id) {
            store.start(vm, password: pw)
            return
        }
        Task { @MainActor in
            let r = await dialog.input(
                title: "解锁加密 VM",
                fields: [HVMUI.InputField(label: "密码",
                                          placeholder: "请输入密码",
                                          secure: true)],
                confirmLabel: "启动",
                probeID: "vmlist.input.password-\(vm.id.uuidString)"
            )
            if case .submitted(let values) = r, let pw = values.first, !pw.isEmpty {
                store.start(vm, password: pw)
            }
        }
    }

    /// 解锁加密 VM (查看/编辑配置用): 弹密码 → store.unlock.
    static func unlock(_ vm: VMSummary,
                       store: NewGUIStore,
                       dialog: HVMUI.DialogPresenter) {
        Task { @MainActor in
            let r = await dialog.input(
                title: "解锁加密 VM",
                fields: [HVMUI.InputField(label: "密码",
                                          placeholder: "请输入密码",
                                          secure: true)],
                confirmLabel: "解锁",
                probeID: "detail.unlock.password-\(vm.id.uuidString)"
            )
            if case .submitted(let values) = r, let pw = values.first, !pw.isEmpty {
                await store.unlock(vm, password: pw)
            }
        }
    }

    /// 删除 (移废纸篓). 先弹 destructive confirm.
    static func confirmDelete(_ vm: VMSummary,
                              store: NewGUIStore,
                              dialog: HVMUI.DialogPresenter) {
        Task { @MainActor in
            let r = await dialog.confirm(
                title: "删除 VM?",
                message: "VM “\(vm.displayName)” 将被移入废纸篓 (可从废纸篓恢复).",
                confirmLabel: "删除",
                destructive: true,
                probeID: "vmlist.confirm.delete-\(vm.id.uuidString)"
            )
            if case .confirmed = r {
                store.delete(vm, mode: .trash)
            }
        }
    }
}

#endif
