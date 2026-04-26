// DiskResizeDialog.swift
// stopped 视图 Disks section 行内 "Resize" 弹出的扩容面板. 套 HVMModal.
// 必须 VM stopped; host 侧只改文件大小; guest 内还要 resize2fs / 分区工具.

import SwiftUI
import HVMBundle
import HVMCore
import HVMQemu
import HVMStorage

struct DiskResizeDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let request: AppModel.DiskResizeRequest

    @State private var newSizeText: String

    init(model: AppModel, errors: ErrorPresenter, request: AppModel.DiskResizeRequest) {
        self._model = Bindable(model)
        self._errors = Bindable(errors)
        self.request = request
        self._newSizeText = State(initialValue: String(request.currentSizeGiB + 1))
    }

    var body: some View {
        HVMModal(
            title: "Resize Disk",
            icon: .info,
            width: 460,
            closeAction: { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                Text("扩容 \(request.item.displayName) 的磁盘 \(request.diskID). host 侧只改文件大小; guest 内还要 resize2fs / 分区工具.")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: HVMSpace.lg) {
                    VStack(alignment: .leading, spacing: HVMSpace.xs) {
                        LabelText("Current")
                        Text("\(request.currentSizeGiB) GB")
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textPrimary)
                            .padding(.horizontal, HVMSpace.md)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                                    .fill(HVMColor.bgCard)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                                    .stroke(HVMColor.border, lineWidth: 1)
                            )
                    }
                    VStack(alignment: .leading, spacing: HVMSpace.xs) {
                        LabelText("New")
                        HVMTextField("\(request.currentSizeGiB + 1)", text: $newSizeText, suffix: "GB")
                    }
                }
            }
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                Button("扩容") { resize() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled((UInt64(newSizeText) ?? 0) <= request.currentSizeGiB)
            }
        }
    }

    private func close() {
        model.diskResizeRequest = nil
    }

    private func resize() {
        do {
            if BundleLock.isBusy(bundleURL: request.item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            guard let toGiB = UInt64(newSizeText), toGiB > request.currentSizeGiB else {
                throw HVMError.config(.missingField(name: "new size 必须 > 当前 \(request.currentSizeGiB) GiB"))
            }
            let delta = (toGiB - request.currentSizeGiB) * (1 << 30)
            try VolumeInfo.assertSpaceAvailable(at: request.item.bundleURL.path, requiredBytes: delta)
            var config = try BundleIO.load(from: request.item.bundleURL)
            let idx: Int?
            if request.diskID == "main" {
                idx = config.disks.firstIndex { $0.role == .main }
            } else {
                // 兼容老 .img 与新 .qcow2 数据盘
                let imgPath   = "\(BundleLayout.disksDirName)/data-\(request.diskID).img"
                let qcow2Path = "\(BundleLayout.disksDirName)/data-\(request.diskID).qcow2"
                idx = config.disks.firstIndex {
                    $0.role == .data && ($0.path == imgPath || $0.path == qcow2Path)
                }
            }
            guard let i = idx else {
                throw HVMError.config(.missingField(name: "disk id=\(request.diskID) 未找到"))
            }
            let absURL = request.item.bundleURL.appendingPathComponent(config.disks[i].path)
            let format = config.disks[i].format
            let qemuImg = format == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
            try DiskFactory.grow(at: absURL, toGiB: toGiB, format: format, qemuImg: qemuImg)
            config.disks[i].sizeGiB = toGiB
            try BundleIO.save(config: config, to: request.item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
