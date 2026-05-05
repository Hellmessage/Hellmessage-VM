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
            // 加密 VM 不走 EditConfigDialog (没明文 config). 入口 (DetailBars CPU/Memory 按钮)
            // 已经在加密 VM 上隐藏; 这里防御兜底跳过.
            if let editItem = model.editConfigItem, editItem.config != nil {
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
            // 加密 VM lifecycle dialog (PR-11e): encrypt / decrypt / rekey 三选一
            if let item = model.encryptItem {
                EncryptVMDialog(model: model, errors: errors, item: item)
            }
            if let item = model.decryptItem {
                DecryptVMDialog(model: model, errors: errors, item: item)
            }
            if let item = model.rekeyItem {
                RekeyVMDialog(model: model, errors: errors, item: item)
            }
            if let req = model.fileTransferRequest {
                FileTransferDialog(model: model, errors: errors, request: req)
            }
            // 加密 VM 启动期密码 modal (PR-11b)
            if let req = model.startPasswordRequest {
                EncryptionPasswordDialog(
                    displayName: req.item.displayName,
                    prompt: "解锁加密 VM",
                    body: "VM \"\(req.item.displayName)\" 已加密 (\(req.item.encryptionScheme?.rawValue ?? "—")). 输入密码继续启动.",
                    errorMessage: req.errorMessage,
                    submitLabel: "启动",
                    onSubmit: { pw in
                        model.startWithEncryptedPassword(req.item, password: pw, errors: errors)
                    },
                    onCancel: {
                        model.startPasswordRequest = nil
                    }
                )
            }
            // sidebar 右键 "配置…" 加密未解锁 → 解锁后停在详情页 (不再弹 EditConfigDialog)
            if let req = model.sidebarUnlockRequest {
                EncryptionPasswordDialog(
                    displayName: req.item.displayName,
                    prompt: "解锁加密 VM",
                    body: "VM \"\(req.item.displayName)\" 已加密. 输入密码解锁查看完整配置.",
                    errorMessage: req.errorMessage,
                    submitLabel: "解锁",
                    onSubmit: { pw in
                        model.unlockFromSidebarMenu(req.item, password: pw, errors: errors)
                    },
                    onCancel: {
                        model.sidebarUnlockRequest = nil
                    }
                )
            }
            ErrorDialogOverlay(presenter: errors)
            ConfirmDialogOverlay(presenter: confirms)
        }
        .allowsHitTesting(model.anyDialogActive(errors: errors, confirms: confirms))
    }
}
