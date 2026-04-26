// DialogOverlay.swift
// SwiftUI 层面做创建向导 + 错误弹窗的叠加. 通过 NSHostingView 覆盖在 AppKit contentView 最上层,
// 不影响底下 AppKit 的 HVMView layout.
// 没弹窗时 allowsHitTesting(false), 鼠标事件穿透到 AppKit 下层.

import SwiftUI

struct DialogOverlay: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    @Bindable var confirms: ConfirmPresenter

    var body: some View {
        ZStack {
            if model.showCreateWizard {
                CreateVMDialog(model: model, errors: errors)
            }
            if let state = model.installState {
                InstallDialog(state: state)
            }
            if let fetchState = model.ipswFetchState {
                IpswFetchDialog(state: fetchState)
            }
            if let editItem = model.editConfigItem {
                EditConfigDialog(model: model, errors: errors, item: editItem)
            }
            if let snapItem = model.snapshotCreateItem {
                SnapshotCreateDialog(model: model, errors: errors, item: snapItem)
            }
            ErrorDialogOverlay(presenter: errors)
            ConfirmDialogOverlay(presenter: confirms)
        }
        .allowsHitTesting(
            model.showCreateWizard ||
            model.installState != nil ||
            model.ipswFetchState != nil ||
            model.editConfigItem != nil ||
            model.snapshotCreateItem != nil ||
            errors.current != nil ||
            confirms.current != nil
        )
    }
}
