// DiskAddDialog.swift
// stopped 视图 Disks section "+ Add Disk" 弹出的新建数据盘面板. 套 HVMModal.
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli disk add).

import SwiftUI
import HVMBundle
import HVMCore
import HVMQemu
import HVMStorage

struct DiskAddDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var sizeText: String = "16"

    var body: some View {
        HVMModal(
            title: "Add Data Disk",
            icon: .info,
            width: 440,
            closeAction: { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                Text("为 \(item.displayName) 新建一块 raw sparse 数据盘. 必须 VM 停止.")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    LabelText("Size")
                    HVMTextField("16", text: $sizeText, suffix: "GB")
                }
            }
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                Button("创建") { create() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled((UInt64(sizeText) ?? 0) < 1)
            }
        }
    }

    private func close() {
        model.diskAddItem = nil
    }

    private func create() {
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            guard let sizeGiB = UInt64(sizeText), sizeGiB >= 1 else {
                throw HVMError.config(.missingField(name: "disk size 必须 >=1 GiB"))
            }
            try VolumeInfo.assertSpaceAvailable(
                at: item.bundleURL.path,
                requiredBytes: sizeGiB * (1 << 30)
            )
            var config = try BundleIO.load(from: item.bundleURL)
            let uuid8 = DiskFactory.newDataDiskUUID8()
            // 数据盘格式跟随 VM engine: VZ → .img (raw), QEMU → .qcow2
            let fileName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: config.engine)
            let relPath = "\(BundleLayout.disksDirName)/\(fileName)"
            let absURL = item.bundleURL.appendingPathComponent(relPath)
            let qemuImg = config.engine == .qemu ? (try? QemuPaths.qemuImgBinary()) : nil
            try DiskFactory.create(at: absURL, sizeGiB: sizeGiB, qemuImg: qemuImg)
            config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: sizeGiB))
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
