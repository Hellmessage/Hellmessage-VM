// DiskAddDialog.swift
// stopped 视图 Disks section "+ Add Disk" 弹出的新建数据盘面板. 套 HVMModal.
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli disk add).

import SwiftUI
import HVMBundle
import HVMCore
import HVMEncryption
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
            guard let sizeGiB = UInt64(sizeText), sizeGiB >= 1 else {
                throw HVMError.config(.missingField(name: "disk size 必须 >=1 GiB"))
            }
            try VolumeInfo.assertSpaceAvailable(
                at: item.bundleURL.path,
                requiredBytes: sizeGiB * (1 << 30)
            )
            // 加密 VM: 走 QcowLuksFactory + sub.qcow2Disk; 明文 VM: 走 DiskFactory.
            // 物理 disk 文件创建在 saveConfig 之前 — 万一 saveConfig 抛错再 cleanup 文件
            // (避免文件已建但 config 没引用的孤儿; 跟 hvm-cli 同步).
            let uuid8 = DiskFactory.newDataDiskUUID8()
            let isEncrypted = item.isEncrypted
            // 加密 VM 必走 qemu engine (设计约束), 数据盘永远 qcow2 (LUKS); 明文跟 engine 走
            let engine: Engine = item.config?.engine ?? (isEncrypted ? .qemu : .vz)
            let format: DiskFormat = engine == .qemu ? .qcow2 : .raw
            let fileName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: engine)
            let relPath = "\(BundleLayout.disksDirName)/\(fileName)"
            let absURL = item.bundleURL.appendingPathComponent(relPath)

            if isEncrypted {
                guard let diskKey = model.unlockedSubKeys[item.id]?.qcow2Disk else {
                    throw HVMError.encryption(.wrongPassword)
                }
                let qemuImg = try QemuPaths.qemuImgBinary()
                try QcowLuksFactory.create(at: absURL,
                                            sizeBytes: sizeGiB * (1 << 30),
                                            key: diskKey,
                                            qemuImg: qemuImg)
            } else {
                let qemuImg = format == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
                try DiskFactory.create(at: absURL, sizeGiB: sizeGiB, format: format, qemuImg: qemuImg)
            }

            do {
                try model.saveConfig(item: item) { config in
                    config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: sizeGiB, format: format))
                }
            } catch {
                // saveConfig 抛错回滚物理 disk 文件防孤儿
                try? FileManager.default.removeItem(at: absURL)
                throw error
            }
            close()
        } catch {
            errors.present(error)
        }
    }
}
