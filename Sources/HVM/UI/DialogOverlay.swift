// DialogOverlay.swift
// SwiftUI 层面做创建向导 + 错误弹窗的叠加. 通过 NSHostingView 覆盖在 AppKit contentView 最上层,
// 不影响底下 AppKit 的 HVMView layout.
// 没弹窗时 allowsHitTesting(false), 鼠标事件穿透到 AppKit 下层.

import SwiftUI

struct DialogOverlay: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        ZStack {
            if model.showCreateWizard {
                CreateVMDialog(model: model, errors: errors)
            }
            ErrorDialogOverlay(presenter: errors)
        }
        .allowsHitTesting(model.showCreateWizard || errors.current != nil)
    }
}
