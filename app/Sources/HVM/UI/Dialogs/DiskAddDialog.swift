// DiskAddDialog.swift
// stopped 视图 Disks section "+ ADD" 按钮弹出的新建数据盘面板.
// 严格按 docs/GUI.md 弹窗约束: X 关 / 禁止遮罩 / 禁止 Esc / 禁止 NSAlert.
//
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli disk add).

import SwiftUI
import HVMBundle
import HVMCore
import HVMStorage

struct DiskAddDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var sizeText: String = "16"

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: HVMSpace.md) {
                    Text("●")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.accent)
                    Text("新建数据盘".uppercased())
                        .font(HVMFont.label)
                        .tracking(1.6)
                        .foregroundStyle(HVMColor.textPrimary)
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("关闭 (Cmd+W)")
                    .keyboardShortcut("w", modifiers: [.command])
                }
                .padding(.horizontal, HVMSpace.lg)
                .padding(.vertical, HVMSpace.md)

                Divider().background(HVMColor.border)

                VStack(alignment: .leading, spacing: HVMSpace.lg) {
                    Text("为 \(item.displayName) 新建一块 raw sparse 数据盘. 必须 VM 停止.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)

                    HStack(spacing: HVMSpace.md) {
                        Text("SIZE")
                            .font(HVMFont.label)
                            .tracking(1.5)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(width: 80, alignment: .leading)
                        TextField("16", text: $sizeText)
                            .textFieldStyle(.roundedBorder)
                            .font(HVMFont.body)
                            .frame(maxWidth: .infinity)
                        Text("gb")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(width: 40, alignment: .leading)
                    }

                    HStack(spacing: HVMSpace.md) {
                        Spacer()
                        Button("取消") { close() }
                            .buttonStyle(GhostButtonStyle())
                        Button("创建") { create() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled((UInt64(sizeText) ?? 0) < 1)
                    }
                }
                .padding(HVMSpace.lg)
            }
            .frame(width: 420)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous)
                    .stroke(HVMColor.borderStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
        }
        .transition(.opacity)
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
            let relPath = "\(BundleLayout.disksDirName)/data-\(uuid8).img"
            let absURL = item.bundleURL.appendingPathComponent(relPath)
            try DiskFactory.create(at: absURL, sizeGiB: sizeGiB)
            config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: sizeGiB))
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
