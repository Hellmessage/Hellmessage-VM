// EditConfigDialog.swift
// stopped 视图里点 cpu / memory 卡片弹出的编辑面板. 套 HVMModal.
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
    @State private var networkChoice: NetworkChoice
    @State private var bridgedInterface: String
    @State private var availableInterfaces: [VmnetSetupHelper.InterfaceInfo] = []

    private enum NetworkChoice: String, CaseIterable, Hashable {
        case nat, bridged, shared
        var label: String {
            switch self {
            case .nat: return "NAT"
            case .bridged: return "Bridged"
            case .shared: return "Shared"
            }
        }
    }

    /// 当前 engine 只读 (edit 时不能改 engine; 改 engine 等价重做装机)
    private var vmnetModesEnabled: Bool {
        item.config.engine == .qemu
    }

    init(model: AppModel, errors: ErrorPresenter, item: AppModel.VMListItem) {
        self._model = Bindable(model)
        self._errors = Bindable(errors)
        self.item = item
        self._cpuText = State(initialValue: String(item.config.cpuCount))
        self._memGiBText = State(initialValue: String(item.config.memoryMiB / 1024))
        let initialNet = item.config.networks.first
        let initialMode = initialNet?.mode ?? .user
        switch initialMode {
        case .user, .none:
            self._networkChoice = State(initialValue: .nat)
            self._bridgedInterface = State(initialValue: "")
        case .vmnetBridged:
            self._networkChoice = State(initialValue: .bridged)
            self._bridgedInterface = State(initialValue: initialNet?.bridgedInterface ?? "")
        case .vmnetShared, .vmnetHost:
            self._networkChoice = State(initialValue: .shared)
            self._bridgedInterface = State(initialValue: "")
        }
    }

    var body: some View {
        HVMModal(
            title: "Edit Configuration",
            icon: .info,
            width: 480,
            closeAction: { close() }
        ) {
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

                networkSection
            }
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                Button("保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onAppear {
            availableInterfaces = VmnetSetupHelper.listInterfaces()
            if bridgedInterface.isEmpty, networkChoice == .bridged {
                bridgedInterface = availableInterfaces.first?.name ?? ""
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            LabelText("Network")
            HStack(spacing: HVMSpace.sm) {
                ForEach(NetworkChoice.allCases, id: \.self) { choice in
                    let disabled = (choice != .nat) && !vmnetModesEnabled
                    Button { networkChoice = choice } label: {
                        HVMNetModeSegment(choice.label, selected: networkChoice == choice, disabled: disabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .frame(maxWidth: .infinity)
                }
            }
            if !vmnetModesEnabled {
                Text("VZ 后端仅 NAT (bridged 等审批; shared 仅 QEMU)")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            if networkChoice == .bridged {
                if availableInterfaces.isEmpty {
                    Text("未检测到可用接口")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                } else {
                    HVMFormSelect(
                        options: availableInterfaces.map { (value: $0.name, label: $0.displayName) },
                        selection: $bridgedInterface,
                        accessibilityLabel: "网卡"
                    )
                }
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
            // UI 内部 NetworkChoice → 数据模型 NetworkMode 5-mode + bridgedInterface 字段.
            let newMode: NetworkMode
            var newBridgedIface: String? = nil
            switch networkChoice {
            case .nat:
                newMode = .user
            case .bridged:
                guard !bridgedInterface.isEmpty else {
                    throw HVMError.config(.missingField(name: "network bridged 接口未选"))
                }
                newMode = .vmnetBridged
                newBridgedIface = bridgedInterface
            case .shared:
                newMode = .vmnetShared
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.cpuCount = cpuInt
            config.memoryMiB = memGiB * 1024
            if !config.networks.isEmpty {
                config.networks[0].mode = newMode
                config.networks[0].bridgedInterface = newBridgedIface
            }
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
