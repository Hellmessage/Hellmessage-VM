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
            if let vwState = model.virtioWinFetchState {
                VirtioWinFetchDialog(state: vwState)
            }
            if let utmState = model.utmGuestToolsFetchState {
                UtmGuestToolsFetchDialog(state: utmState)
            }
            if let pickerState = model.ipswCatalogPicker {
                IpswCatalogPicker(model: model, errors: errors, onSelect: pickerState.onSelect)
            }
            if let osPicker = model.osImagePickerRequest {
                OSImagePickerDialog(model: model, errors: errors, request: osPicker)
            }
            if let osFetch = model.osImageFetchState {
                OSImageFetchDialog(state: osFetch)
            }
            if let editItem = model.editConfigItem {
                EditConfigDialog(model: model, errors: errors, item: editItem)
            }
            if let snapItem = model.snapshotCreateItem {
                SnapshotCreateDialog(model: model, errors: errors, item: snapItem)
            }
            if let cloneSrc = model.cloneItem {
                CloneVMDialog(model: model, errors: errors, item: cloneSrc)
            }
            if let diskAdd = model.diskAddItem {
                DiskAddDialog(model: model, errors: errors, item: diskAdd)
            }
            if let resize = model.diskResizeRequest {
                DiskResizeDialog(model: model, errors: errors, request: resize)
            }
            ErrorDialogOverlay(presenter: errors)
            ConfirmDialogOverlay(presenter: confirms)
        }
        .allowsHitTesting(model.anyDialogActive(errors: errors, confirms: confirms))
    }
}
