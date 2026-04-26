// DiskResizeDialog.swift
// stopped 视图 Disks section 行内 "RESIZE" 按钮弹出的扩容面板.
// 严格按 docs/GUI.md 弹窗约束: X 关 / 禁止遮罩 / 禁止 Esc / 禁止 NSAlert.
//
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli disk resize).
// host 侧只改文件大小; guest 内还要 resize2fs / 分区工具.

import SwiftUI
import HVMBundle
import HVMCore
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
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: HVMSpace.md) {
                    Text("●")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.accent)
                    Text("扩容磁盘".uppercased())
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
                    Text("扩容 \(request.item.displayName) 的磁盘 \(request.diskID). host 侧只改文件大小; guest 内还要 resize2fs / 分区工具.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)

                    HStack(spacing: HVMSpace.md) {
                        Text("CURRENT")
                            .font(HVMFont.label)
                            .tracking(1.5)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(width: 80, alignment: .leading)
                        Text("\(request.currentSizeGiB) gb")
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textPrimary)
                        Spacer()
                    }

                    HStack(spacing: HVMSpace.md) {
                        Text("NEW")
                            .font(HVMFont.label)
                            .tracking(1.5)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(width: 80, alignment: .leading)
                        TextField("\(request.currentSizeGiB + 1)", text: $newSizeText)
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
                        Button("扩容") { resize() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled((UInt64(newSizeText) ?? 0) <= request.currentSizeGiB)
                    }
                }
                .padding(HVMSpace.lg)
            }
            .frame(width: 460)
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
                idx = config.disks.firstIndex {
                    $0.role == .data &&
                    $0.path == "\(BundleLayout.disksDirName)/data-\(request.diskID).img"
                }
            }
            guard let i = idx else {
                throw HVMError.config(.missingField(name: "disk id=\(request.diskID) 未找到"))
            }
            let absURL = request.item.bundleURL.appendingPathComponent(config.disks[i].path)
            try DiskFactory.grow(at: absURL, toGiB: toGiB)
            config.disks[i].sizeGiB = toGiB
            try BundleIO.save(config: config, to: request.item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
