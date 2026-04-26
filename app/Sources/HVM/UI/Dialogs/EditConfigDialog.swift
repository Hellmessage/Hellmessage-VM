// EditConfigDialog.swift
// stopped 视图里点 cpu / memory 卡片弹出的编辑面板.
// 严格按 docs/GUI.md 弹窗约束: X 关 / 禁止遮罩 / 禁止 Esc / 禁止 NSAlert.
//
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli config set).

import SwiftUI
import HVMBundle
import HVMCore

struct EditConfigDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var cpuText: String
    @State private var memGiBText: String

    init(model: AppModel, errors: ErrorPresenter, item: AppModel.VMListItem) {
        self._model = Bindable(model)
        self._errors = Bindable(errors)
        self.item = item
        self._cpuText = State(initialValue: String(item.config.cpuCount))
        self._memGiBText = State(initialValue: String(item.config.memoryMiB / 1024))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶栏
                HStack(spacing: HVMSpace.md) {
                    Text("●")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.accent)
                    Text("编辑配置".uppercased())
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
                    Text("修改 \(item.displayName) 的资源配置. 必须 VM 停止时才能保存.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)

                    formRow(label: "CPU", suffix: "cores", text: $cpuText)
                    formRow(label: "MEMORY", suffix: "gb", text: $memGiBText)

                    HStack(spacing: HVMSpace.md) {
                        Spacer()
                        Button("取消") { close() }
                            .buttonStyle(GhostButtonStyle())
                        Button("保存") { save() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: [.command])
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

    @ViewBuilder
    private func formRow(label: String, suffix: String, text: Binding<String>) -> some View {
        HStack(spacing: HVMSpace.md) {
            Text(label)
                .font(HVMFont.label)
                .tracking(1.5)
                .foregroundStyle(HVMColor.textTertiary)
                .frame(width: 80, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(HVMFont.body)
                .frame(maxWidth: .infinity)
            Text(suffix)
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
                .frame(width: 40, alignment: .leading)
        }
    }

    private func close() {
        model.editConfigItem = nil
    }

    private func save() {
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            guard let cpuInt = Int(cpuText), cpuInt >= 1 else {
                throw HVMError.config(.missingField(name: "cpu 必须 >=1"))
            }
            guard let memGiB = UInt64(memGiBText), memGiB >= 1 else {
                throw HVMError.config(.missingField(name: "memory 必须 >=1 GiB"))
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.cpuCount = cpuInt
            config.memoryMiB = memGiB * 1024
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
