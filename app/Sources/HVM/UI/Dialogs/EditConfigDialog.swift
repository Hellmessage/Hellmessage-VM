// EditConfigDialog.swift
// stopped 视图里点 cpu / memory 卡片弹出的编辑面板. 套 HVMModal.
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli config set).
//
// 网络区块走 VMSettingsNetworkSection (hell-vm 同款多 NIC 卡片 + 自绘下拉 + 集成 daemon
// 安装面板, 提权用 VMnetSupervisor osascript admin Touch ID).

import SwiftUI
import HVMBundle
import HVMCore

struct EditConfigDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var cpuText: String
    @State private var memGiBText: String
    /// 整张 VMConfig 的 draft, VMSettingsNetworkSection 直接绑定 networks 段.
    @State private var draft: VMConfig

    init(model: AppModel, errors: ErrorPresenter, item: AppModel.VMListItem) {
        self._model = Bindable(model)
        self._errors = Bindable(errors)
        self.item = item
        self._cpuText = State(initialValue: String(item.config.cpuCount))
        self._memGiBText = State(initialValue: String(item.config.memoryMiB / 1024))
        self._draft = State(initialValue: item.config)
    }

    var body: some View {
        HVMModal(
            title: "Edit Configuration",
            icon: .info,
            width: 560,
            closeAction: { close() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: HVMSpace.lg) {
                    Text("修改 \(item.displayName) 的资源配置. 必须 VM 停止. Engine (\(item.config.engine.rawValue)) 不可改.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: HVMSpace.md) {
                        VStack(alignment: .leading, spacing: HVMSpace.xs) {
                            LabelText("CPU")
                            HVMTextField("4", text: $cpuText, suffix: "cores")
                        }
                        VStack(alignment: .leading, spacing: HVMSpace.xs) {
                            LabelText("Memory")
                            HVMTextField("8", text: $memGiBText, suffix: "GB")
                        }
                    }

                    // 剪贴板共享 — 仅 QEMU 后端 (VZ macOS guest 自带剪贴板)
                    if item.config.engine == .qemu {
                        HVMToggle(
                            "剪贴板共享",
                            isOn: $draft.clipboardSharingEnabled,
                            help: "host ↔ guest UTF-8 文本双向同步, 走 vdagent virtio-serial. 运行中也可在详情顶栏即时切换"
                        )
                        HVMToggle(
                            "macOS 风格快捷键",
                            isOn: $draft.macStyleShortcuts,
                            help: "把 host cmd 当 guest ctrl 转发 (cmd+c → ctrl+c 等). 关闭后回到 cmd → Win 键. 关闭并重开 VM 详情或独立窗口生效"
                        )
                    }

                    VMSettingsNetworkSection(draft: $draft, item: item)
                }
                .padding(.vertical, HVMSpace.xs)
            }
            .frame(maxHeight: 560)
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                Button("保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
            }
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
            // 校验每张 NIC: vmnetBridged 必须有接口
            for (idx, net) in draft.networks.enumerated() where net.enabled {
                if net.mode == .vmnetBridged,
                   (net.bridgedInterface ?? "").isEmpty {
                    throw HVMError.config(.missingField(name: "networks[\(idx)] bridged 接口未选"))
                }
                if !NetworkSpec.isValidMAC(net.macAddress) {
                    throw HVMError.config(.missingField(name: "networks[\(idx)] MAC 格式非法 (\(net.macAddress))"))
                }
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.cpuCount = cpuInt
            config.memoryMiB = memGiB * 1024
            config.networks = draft.networks
            config.clipboardSharingEnabled = draft.clipboardSharingEnabled
            config.macStyleShortcuts = draft.macStyleShortcuts
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
