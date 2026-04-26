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
        // 从当前 NetworkSpec 推导初始 networkChoice + bridgedInterface
        let initialMode = item.config.networks.first?.mode ?? .nat
        switch initialMode {
        case .nat:                       self._networkChoice = State(initialValue: .nat); self._bridgedInterface = State(initialValue: "")
        case .bridged(let iface):        self._networkChoice = State(initialValue: .bridged); self._bridgedInterface = State(initialValue: iface)
        case .shared:                    self._networkChoice = State(initialValue: .shared); self._bridgedInterface = State(initialValue: "")
        }
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
                    Text("修改 \(item.displayName) 的资源配置. 必须 VM 停止时才能保存. Engine (\(item.config.engine.rawValue)) 不可改.")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)

                    formRow(label: "CPU", suffix: "cores", text: $cpuText)
                    formRow(label: "MEMORY", suffix: "gb", text: $memGiBText)

                    networkSection

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
        .onAppear {
            availableInterfaces = VmnetSetupHelper.listInterfaces()
            if bridgedInterface.isEmpty, networkChoice == .bridged {
                bridgedInterface = availableInterfaces.first?.name ?? ""
            }
        }
    }

    /// Network 段: NAT 总可选; bridged/shared 仅 engine=qemu (与 CreateVMDialog 一致)
    @ViewBuilder
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            Text("NETWORK")
                .font(HVMFont.label)
                .tracking(1.5)
                .foregroundStyle(HVMColor.textTertiary)
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
                Text("// VZ 后端仅 NAT (bridged 等审批; shared 仅 QEMU)")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            if networkChoice == .bridged {
                if availableInterfaces.isEmpty {
                    Text("// 未检测到可用接口")
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textTertiary)
                } else {
                    HVMFormMenuField {
                        Picker("", selection: $bridgedInterface) {
                            ForEach(availableInterfaces, id: \.name) { ifc in
                                Text(ifc.displayName).tag(ifc.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
        }
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
            // 推导新 NetworkMode
            let newMode: NetworkMode
            switch networkChoice {
            case .nat: newMode = .nat
            case .bridged:
                guard !bridgedInterface.isEmpty else {
                    throw HVMError.config(.missingField(name: "network bridged 接口未选"))
                }
                newMode = .bridged(interface: bridgedInterface)
            case .shared: newMode = .shared
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.cpuCount = cpuInt
            config.memoryMiB = memGiB * 1024
            // 替换第一个 NIC 的 mode (一期单 NIC). 保留原 macAddress 不变.
            if !config.networks.isEmpty {
                config.networks[0].mode = newMode
            }
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
            close()
        } catch {
            errors.present(error)
        }
    }
}
