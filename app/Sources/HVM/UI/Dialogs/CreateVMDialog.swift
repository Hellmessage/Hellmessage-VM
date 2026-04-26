// CreateVMDialog.swift
// 创建向导. 套 HVMModal, 表单全部用 HVMTextField / HVMFormSelect / HVMToggle / HVMNetModeSegment.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HVMBundle
import HVMCore
import HVMInstall
import HVMNet
import HVMQemu
import HVMStorage

struct CreateVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    @State private var name: String = ""
    @State private var guestOS: GuestOSType = .linux
    @State private var cpu: Int = 4
    @State private var memoryGiB: Int = 4
    @State private var diskGiB: Int = 64
    @State private var isoPath: String = ""
    @State private var ipswPath: String = ""
    @State private var creating: Bool = false
    @State private var ipswCache: [IPSWCacheItem] = []
    @State private var qemuBackendAvailable: Bool = false
    @State private var linuxEngine: Engine = .vz
    @State private var networkChoice: NetworkChoice = .nat
    @State private var bridgedInterface: String = ""
    @State private var availableInterfaces: [VmnetSetupHelper.InterfaceInfo] = []
    @State private var daemonReady: Bool = false
    @State private var helperFallbackCommand: String? = nil

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

    private var effectiveEngine: Engine {
        switch guestOS {
        case .macOS:   return .vz
        case .windows: return .qemu
        case .linux:   return linuxEngine
        }
    }

    private var vmnetModesEnabled: Bool {
        effectiveEngine == .qemu
    }

    private var installerPathValid: Bool {
        switch guestOS {
        case .linux, .windows: return !isoPath.isEmpty
        case .macOS:           return !ipswPath.isEmpty
        }
    }

    var body: some View {
        HVMModal(
            title: "Create Virtual Machine",
            icon: .info,
            width: 540,
            closeAction: { model.showCreateWizard = false }
        ) {
            ScrollView {
                form
            }
            .frame(maxHeight: 560)
        } footer: {
            HVMModalFooter {
                Button("Cancel") { model.showCreateWizard = false }
                    .buttonStyle(GhostButtonStyle())
                Button(guestOS == .macOS ? "Create & Install" : "Create") { createAction() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(creating || name.isEmpty || !installerPathValid)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onAppear {
            reloadCache()
            qemuBackendAvailable = (try? QemuPaths.resolveRoot()) != nil
            availableInterfaces = VmnetSetupHelper.listInterfaces()
            if bridgedInterface.isEmpty {
                bridgedInterface = availableInterfaces.first?.name ?? ""
            }
            refreshDaemonReady()
        }
        .onChange(of: guestOS) { _, newOS in
            reloadCache()
            if newOS != .linux { linuxEngine = .vz }
            if !vmnetModesEnabled, networkChoice != .nat {
                networkChoice = .nat
            }
        }
        .onChange(of: linuxEngine) { _, _ in
            if !vmnetModesEnabled, networkChoice != .nat {
                networkChoice = .nat
            }
        }
        .onChange(of: networkChoice) { _, _ in refreshDaemonReady() }
        .onChange(of: bridgedInterface) { _, _ in refreshDaemonReady() }
        .onChange(of: model.ipswFetchState == nil) { _, _ in reloadCache() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            field("Name") {
                HVMTextField("linux-vm", text: $name)
            }

            field("Guest OS") {
                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    HStack(spacing: HVMSpace.sm) {
                        Button { guestOS = .linux } label: {
                            osChip("Linux", selected: guestOS == .linux)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        Button { guestOS = .macOS } label: {
                            osChip("macOS", selected: guestOS == .macOS)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        Button { guestOS = .windows } label: {
                            osChip("Windows", selected: guestOS == .windows,
                                   disabled: !qemuBackendAvailable)
                        }
                        .buttonStyle(.plain)
                        .disabled(!qemuBackendAvailable)
                        .frame(maxWidth: .infinity)
                        .help(qemuBackendAvailable
                              ? "实验性: Windows arm64 走 QEMU 后端"
                              : "Windows 需要 QEMU 后端: 请先 make qemu (或 make build-all)")
                    }
                    if guestOS == .windows {
                        Text("实验性: Windows arm64 走 QEMU 后端 (强制 engine=qemu)")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    } else if !qemuBackendAvailable {
                        Text("Windows 暂不可选 — third_party/qemu-stage 未就绪 (需先 make qemu)")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }

            if guestOS == .linux {
                field("Engine") {
                    HStack(spacing: HVMSpace.sm) {
                        Button { linuxEngine = .vz } label: {
                            osChip("VZ", selected: linuxEngine == .vz)
                        }
                        .buttonStyle(.plain)
                        Button { linuxEngine = .qemu } label: {
                            osChip("QEMU", selected: linuxEngine == .qemu, disabled: !qemuBackendAvailable)
                        }
                        .buttonStyle(.plain)
                        .disabled(!qemuBackendAvailable)
                        .help(qemuBackendAvailable
                              ? "QEMU 后端: 支持 socket_vmnet 桥接 / 共享网络"
                              : "QEMU 暂不可选 — 需先 make qemu (或 make build-all)")
                        Spacer()
                    }
                }
            }

            HStack(spacing: HVMSpace.md) {
                field("CPU") {
                    stepperRow(unit: "cores", binding: $cpu, range: 1...16, step: 1)
                }
                field("Memory") {
                    stepperRow(unit: "GB", binding: $memoryGiB, range: 1...128, step: 1)
                }
                field("Disk") {
                    stepperRow(unit: "GB", binding: $diskGiB, range: 8...2048, step: 8)
                }
            }

            networkSection

            switch guestOS {
            case .linux, .windows:
                field("Installer ISO") {
                    HVMTextField(
                        guestOS == .windows
                            ? "/path/to/Win11_arm64.iso"
                            : "/path/to/ubuntu-arm64.iso",
                        text: $isoPath,
                        action: HVMTextField.ActionButton("Browse") { pickISO() }
                    )
                }
            case .macOS:
                field("Installer IPSW") {
                    VStack(alignment: .leading, spacing: HVMSpace.sm) {
                        HVMTextField(
                            "/path/to/UniversalMac_*.ipsw",
                            text: $ipswPath,
                            action: HVMTextField.ActionButton("Browse") { pickIPSW() }
                        )
                        HStack(spacing: HVMSpace.sm) {
                            Button("Use Latest") { fetchLatestIPSW() }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(creating || model.ipswFetchState != nil)
                                .help("拉 Apple 推荐的最新 IPSW")
                            Button("Choose Version…") { openCatalogPicker() }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(creating || model.ipswFetchState != nil)
                                .help("打开 Apple catalog, 选择具体的 macOS 版本下载")
                            Spacer()
                        }
                        if !ipswCache.isEmpty {
                            cachePicker
                        }
                        Text("约 10-15 GiB. 已缓存的 build 不会重复下载.")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }
        }
        .padding(HVMSpace.lg)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText(title)
            content()
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        field("Network") {
            VStack(alignment: .leading, spacing: HVMSpace.sm) {
                HStack(spacing: HVMSpace.sm) {
                    ForEach(NetworkChoice.allCases, id: \.self) { choice in
                        let disabled = (choice != .nat) && !vmnetModesEnabled
                        Button { networkChoice = choice } label: {
                            HVMNetModeSegment(choice.label, selected: networkChoice == choice, disabled: disabled)
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .frame(maxWidth: .infinity)
                        .help(networkHelp(for: choice))
                    }
                }
                if !vmnetModesEnabled {
                    Text("Bridged / Shared 仅 QEMU 后端可选 (VZ bridged 等 Apple entitlement 审批)")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                }
                if networkChoice == .bridged {
                    bridgedInterfacePicker
                }
                if networkChoice == .bridged || networkChoice == .shared {
                    if !daemonReady {
                        daemonHelperCard
                    }
                }
            }
        }
    }

    private func networkHelp(for c: NetworkChoice) -> String {
        switch c {
        case .nat: return "QEMU SLIRP / VZ NAT: 默认网络, guest 可出网"
        case .bridged: return vmnetModesEnabled
            ? "socket_vmnet bridged: guest IP 落在物理 LAN 段, 跨机可达"
            : "需 QEMU 后端"
        case .shared: return vmnetModesEnabled
            ? "socket_vmnet shared: NAT 内网, host 与 guest 互通, 多 guest 互通"
            : "需 QEMU 后端"
        }
    }

    @ViewBuilder
    private var bridgedInterfacePicker: some View {
        if availableInterfaces.isEmpty {
            Text("未检测到可用接口 (要求 IFF_UP & IFF_RUNNING + 非 lo / utun / awdl)")
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

    private func refreshDaemonReady() {
        switch networkChoice {
        case .nat:     daemonReady = true
        case .bridged: daemonReady = bridgedInterface.isEmpty
            ? false
            : VmnetSetupHelper.daemonReady(.bridged(interface: bridgedInterface))
        case .shared:  daemonReady = VmnetSetupHelper.daemonReady(.shared)
        }
    }

    @ViewBuilder
    private var daemonHelperCard: some View {
        let modeLabel = (networkChoice == .bridged) ? "bridged(\(bridgedInterface))" : "shared"
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(HVMColor.statusPaused)
                Text("socket_vmnet \(modeLabel) daemon 未跑")
                    .font(HVMFont.caption.weight(.semibold))
                    .foregroundStyle(HVMColor.textPrimary)
            }
            Text("一次 sudo 装 launchd daemon, 之后所有 VM 启动 / 关闭不再 sudo. 详见 scripts/install-vmnet-helper.sh.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HVMSpace.sm) {
                Button("装 daemon") { runDaemonHelper() }
                    .buttonStyle(GhostButtonStyle())
                if let cmd = helperFallbackCommand {
                    Button("复制命令") {
                        VmnetSetupHelper.copyToClipboard(cmd)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Button("已就绪") { refreshDaemonReady() }
                    .buttonStyle(GhostButtonStyle())
                    .help("跑完脚本后点这里重新探测")
                Spacer()
            }
            if let cmd = helperFallbackCommand {
                Text(cmd)
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)
                    .padding(HVMSpace.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: HVMRadius.sm).fill(HVMColor.bgBase))
            }
        }
        .padding(HVMSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
        .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
    }

    private func runDaemonHelper() {
        let extra: [String]
        if networkChoice == .bridged, !bridgedInterface.isEmpty {
            extra = [bridgedInterface]
        } else {
            extra = []
        }
        switch VmnetSetupHelper.runInstallScript(extraArgs: extra) {
        case .launched:
            helperFallbackCommand = nil
        case .fallbackCommand(let cmd):
            helperFallbackCommand = cmd
        case .scriptMissing:
            errors.present(HVMError.backend(.vzInternal(
                description: "未找到 install-vmnet-helper.sh; 请重新 make build (脚本会被打包入 .app)"
            )))
        }
    }

    /// CPU / Memory / Disk 数字 stepper. 用 HVMTextField + Stepper, 避开 SwiftUI 原生 TextField.
    @ViewBuilder
    private func stepperRow(unit: String, binding: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        let textBinding = Binding<String>(
            get: { String(binding.wrappedValue) },
            set: { newText in
                if let v = Int(newText) {
                    binding.wrappedValue = max(range.lowerBound, min(range.upperBound, v))
                }
            }
        )
        HStack(spacing: HVMSpace.sm) {
            HVMTextField("", text: textBinding, suffix: unit)
            Stepper("",
                    value: clampedBinding(binding, range: range),
                    in: range, step: step)
                .labelsHidden()
        }
    }

    private func clampedBinding(_ source: Binding<Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { source.wrappedValue },
            set: { source.wrappedValue = max(range.lowerBound, min(range.upperBound, $0)) }
        )
    }

    /// guest os / engine 单选按钮 chip. 选中蓝底白字, 未选中灰边深底.
    @ViewBuilder
    private func osChip(_ label: String, selected: Bool, disabled: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(disabled
                             ? HVMColor.textTertiary
                             : (selected ? HVMColor.textOnAccent : HVMColor.textSecondary))
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md)
                    .fill(selected ? HVMColor.accent : HVMColor.bgCardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.md)
                    .stroke(selected ? Color.clear : HVMColor.border, lineWidth: 1)
            )
            .opacity(disabled ? 0.45 : 1.0)
    }

    private func pickISO() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.diskImage, .data]
        if panel.runModal() == .OK, let url = panel.url {
            isoPath = url.path
        }
    }

    private func fetchLatestIPSW() {
        model.startIpswFetch(errors: errors) { localURL in
            self.ipswPath = localURL.path
            self.reloadCache()
        }
    }

    private func openCatalogPicker() {
        model.ipswCatalogPicker = AppModel.IpswCatalogPickerState { entry in
            model.startIpswFetch(entry: entry, errors: errors) { localURL in
                self.ipswPath = localURL.path
                self.reloadCache()
            }
        }
    }

    private func reloadCache() {
        ipswCache = IPSWFetcher.listCache()
    }

    @ViewBuilder
    private var cachePicker: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("Cached IPSW")
            VStack(spacing: 0) {
                ForEach(Array(ipswCache.enumerated()), id: \.element.buildVersion) { idx, item in
                    if idx > 0 { Rectangle().fill(HVMColor.border).frame(height: 1) }
                    Button {
                        ipswPath = item.path
                    } label: {
                        HStack(spacing: HVMSpace.sm) {
                            Image(systemName: ipswPath == item.path ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(ipswPath == item.path ? HVMColor.accent : HVMColor.textTertiary)
                            Text(item.buildVersion)
                                .font(HVMFont.bodyBold)
                                .foregroundStyle(HVMColor.textPrimary)
                            Text(formatCacheSize(item.sizeBytes))
                                .font(HVMFont.small)
                                .foregroundStyle(HVMColor.textTertiary)
                                .monospacedDigit()
                            Spacer()
                            Text(item.path)
                                .font(HVMFont.monoSmall)
                                .foregroundStyle(HVMColor.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, HVMSpace.sm)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    private func formatCacheSize(_ n: Int64) -> String {
        let gb = 1024.0 * 1024 * 1024
        let mb = 1024.0 * 1024
        let v = Double(n)
        if v >= gb { return String(format: "%.1f GiB", v / gb) }
        if v >= mb { return String(format: "%.0f MiB", v / mb) }
        return "\(n) B"
    }

    private func pickIPSW() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let ipswType = UTType("com.apple.itunes.ipsw") ?? .data
        panel.allowedContentTypes = [ipswType, .data]
        if panel.runModal() == .OK, let url = panel.url {
            ipswPath = url.path
        }
    }

    private func createAction() {
        creating = true
        if guestOS == .windows {
            model.startVirtioWinFetch(errors: errors) {
                self.proceedWithBundleCreation()
            }
            return
        }
        proceedWithBundleCreation()
    }

    private func proceedWithBundleCreation() {
        do {
            switch guestOS {
            case .linux, .windows: try ISOValidator.validate(at: isoPath)
            case .macOS:
                guard FileManager.default.fileExists(atPath: ipswPath) else {
                    throw HVMError.install(.ipswNotFound(path: ipswPath))
                }
            }

            let engineValue: Engine = effectiveEngine
            let macOSSpec: MacOSSpec?
            let linuxSpec: LinuxSpec?
            let windowsSpec: WindowsSpec?
            switch guestOS {
            case .linux:
                macOSSpec = nil; linuxSpec = LinuxSpec(); windowsSpec = nil
            case .macOS:
                macOSSpec = MacOSSpec(ipsw: ipswPath, autoInstalled: false)
                linuxSpec = nil; windowsSpec = nil
            case .windows:
                macOSSpec = nil; linuxSpec = nil; windowsSpec = WindowsSpec()
            }

            let netMode: NetworkMode
            switch networkChoice {
            case .nat: netMode = .nat
            case .bridged:
                guard !bridgedInterface.isEmpty else {
                    throw HVMError.config(.missingField(name: "network bridged 接口未选"))
                }
                netMode = .bridged(interface: bridgedInterface)
            case .shared: netMode = .shared
            }

            // engine-aware 主盘: VZ → os.img (raw), QEMU → os.qcow2
            let mainFormat: DiskFormat = engineValue == .qemu ? .qcow2 : .raw
            let mainDiskFile = "\(BundleLayout.disksDirName)/\(BundleLayout.mainDiskFileName(for: engineValue))"
            let mainDisk = DiskSpec(
                role: .main,
                path: mainDiskFile,
                sizeGiB: UInt64(diskGiB),
                format: mainFormat
            )
            let config = VMConfig(
                displayName: name,
                guestOS: guestOS,
                engine: engineValue,
                cpuCount: cpu,
                memoryMiB: UInt64(memoryGiB) * 1024,
                disks: [mainDisk],
                networks: [NetworkSpec(mode: netMode, macAddress: MACAddressGenerator.random())],
                installerISO: guestOS == .macOS ? nil : isoPath,
                bootFromDiskOnly: false,
                macOS: macOSSpec,
                linux: linuxSpec,
                windows: windowsSpec
            )

            try HVMPaths.ensure(HVMPaths.vmsRoot)
            let bundleURL = HVMPaths.vmsRoot.appendingPathComponent("\(name).hvmz", isDirectory: true)
            try VolumeInfo.assertSpaceAvailable(
                at: HVMPaths.vmsRoot.path,
                requiredBytes: UInt64(diskGiB) * (1 << 30)
            )
            try BundleIO.create(at: bundleURL, config: config)
            let qemuImg = mainFormat == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
            try DiskFactory.create(
                at: bundleURL.appendingPathComponent(mainDiskFile),
                sizeGiB: UInt64(diskGiB),
                format: mainFormat,
                qemuImg: qemuImg
            )

            if guestOS == .windows, let qemuRoot = try? QemuPaths.resolveRoot() {
                let nvramURL = BundleLayout.nvramURL(bundleURL)
                let varsTemplate = qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-vars.fd")
                if FileManager.default.fileExists(atPath: varsTemplate.path),
                   !FileManager.default.fileExists(atPath: nvramURL.path) {
                    try FileManager.default.createDirectory(
                        at: nvramURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: varsTemplate, to: nvramURL)
                }
            }
            model.showCreateWizard = false
            model.refreshList()
            model.selectedID = config.id

            if guestOS == .macOS {
                model.startInstall(
                    bundleURL: bundleURL,
                    config: config,
                    ipswURL: URL(fileURLWithPath: ipswPath),
                    errors: errors
                )
            }
        } catch {
            errors.present(error)
        }
        creating = false
    }
}
