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
    @State private var creationSource: CreationSource = .installer
    @State private var importDiskPath: String = ""
    @State private var importDiskInfo: DiskFactory.ImportableDiskInfo? = nil
    @State private var importDiskError: String? = nil
    @State private var networkChoice: NetworkChoice = .nat
    @State private var bridgedInterface: String = ""
    @State private var availableInterfaces: [HostNetworkInterface] = []
    @State private var daemonReady: Bool = false

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

    /// VM 创建源: 装机 ISO / IPSW vs 直接导入现成磁盘镜像.
    /// 仅 Linux 暴露切换; macOS 强制走 IPSW 装机, Windows 强制走 ISO 装机.
    private enum CreationSource: String, CaseIterable, Hashable {
        case installer
        case importDisk
        var label: String {
            switch self {
            case .installer: return "Install from ISO"
            case .importDisk: return "Import disk image"
            }
        }
    }

    private var effectiveEngine: Engine {
        switch guestOS {
        case .macOS:   return .vz
        case .windows: return .qemu
        case .linux:
            // 导入模式下 engine 由镜像格式锁定 (qcow2→qemu, raw→vz), 忽略 linuxEngine 选择
            if creationSource == .importDisk, let info = importDiskInfo {
                return info.format == .qcow2 ? .qemu : .vz
            }
            return linuxEngine
        }
    }

    private var vmnetModesEnabled: Bool {
        effectiveEngine == .qemu
    }

    private var installerPathValid: Bool {
        // Linux 导入模式: 必须有路径且 inspect 通过 (importDiskInfo != nil); macOS / Windows 不暴露此模式
        if guestOS == .linux, creationSource == .importDisk {
            return !importDiskPath.isEmpty && importDiskInfo != nil
        }
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
            ScrollView(showsIndicators: false) {
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
            availableInterfaces = HostNetworkInterfaces.list()
            if bridgedInterface.isEmpty {
                bridgedInterface = availableInterfaces.first(where: { $0.isActive })?.name
                    ?? availableInterfaces.first?.name
                    ?? ""
            }
            refreshDaemonReady()
        }
        .onChange(of: guestOS) { _, newOS in
            reloadCache()
            if newOS != .linux {
                linuxEngine = .vz
                // 导入模式仅 Linux 暴露; 切到 macOS/Windows 时回退到装机模式并清状态
                if creationSource != .installer {
                    resetImportState()
                    creationSource = .installer
                }
            }
            if !vmnetModesEnabled, networkChoice != .nat {
                networkChoice = .nat
            }
        }
        .onChange(of: linuxEngine) { _, _ in
            if !vmnetModesEnabled, networkChoice != .nat {
                networkChoice = .nat
            }
        }
        .onChange(of: creationSource) { _, newSource in
            if newSource == .installer { resetImportState() }
            if !vmnetModesEnabled, networkChoice != .nat { networkChoice = .nat }
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
                        Text("Windows 暂不可选 — 此版本未含 QEMU 后端 (需先 make qemu 或 make build-all)")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }

            if guestOS == .linux {
                field("Source") {
                    HStack(spacing: HVMSpace.sm) {
                        ForEach(CreationSource.allCases, id: \.self) { source in
                            let disabled = (source == .importDisk) && !qemuBackendAvailable
                            Button { if !disabled { creationSource = source } } label: {
                                HVMNetModeSegment(source.label, selected: creationSource == source, disabled: disabled)
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                            .frame(maxWidth: .infinity)
                            .help(source == .importDisk
                                  ? (qemuBackendAvailable
                                     ? "导入现成 qcow2 / raw 镜像 (例 OpenWrt / Debian cloud image), 跳过装机直接 boot"
                                     : "导入磁盘需 qemu-img — 请先 make qemu (或 make build-all)")
                                  : "用 ISO 走完整装机流程")
                        }
                    }
                }
            }

            if guestOS == .linux, creationSource == .installer {
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
            case .linux where creationSource == .importDisk:
                field("Disk image") {
                    importDiskField
                }
            case .linux, .windows:
                field("Installer ISO") {
                    VStack(alignment: .leading, spacing: HVMSpace.sm) {
                        HVMTextField(
                            guestOS == .windows
                                ? "/path/to/Win11_arm64.iso"
                                : "/path/to/ubuntu-arm64.iso",
                            text: $isoPath,
                            action: HVMTextField.ActionButton("Browse") { pickISO() }
                        )
                        HStack(spacing: HVMSpace.sm) {
                            Button("Download…") { openOSImagePicker() }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(
                                    creating
                                    || model.osImagePickerRequest != nil
                                    || model.osImageFetchState != nil
                                )
                                .help(guestOS == .windows
                                      ? "Win11/Win10 ARM 无官方直链, 走 Custom URL 自动下载"
                                      : "选 Linux 发行版自动下载, 或走 Custom URL 兜底")
                            Spacer()
                        }
                    }
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
                options: availableInterfaces.map { (value: $0.name, label: $0.displayLabel) },
                selection: $bridgedInterface,
                accessibilityLabel: "网卡"
            )
        }
    }

    /// 探测 socket_vmnet daemon 是否就绪. 不再走 VmnetSetupHelper, 直接 SocketPaths.isReady.
    private func refreshDaemonReady() {
        switch networkChoice {
        case .nat:
            daemonReady = true
        case .bridged:
            daemonReady = !bridgedInterface.isEmpty
                && SocketPaths.isReady(SocketPaths.vmnetBridged(interface: bridgedInterface))
        case .shared:
            daemonReady = SocketPaths.isReady(SocketPaths.vmnetShared)
        }
    }

    /// daemon 缺失时的简短引导卡: 不在 wizard 里直接装 daemon (避免多步骤交互),
    /// 提示用户去 EditConfigDialog → 网络面板 走 VMnetSupervisor.installAllDaemons (osascript admin Touch ID).
    @ViewBuilder
    private var daemonHelperCard: some View {
        let modeLabel = (networkChoice == .bridged) ? "bridged(\(bridgedInterface))" : "shared"
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.statusPaused)
                Text("socket_vmnet \(modeLabel) daemon 未就绪")
                    .font(HVMFont.caption.weight(.semibold))
                    .foregroundStyle(HVMColor.textPrimary)
            }
            Text("用户机器需先 brew install socket_vmnet, 然后在 编辑配置 → 网络 面板点 \"安装 daemon\" 走 osascript Touch ID 一次到位.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HVMSpace.sm) {
                Button("已就绪") { refreshDaemonReady() }
                    .buttonStyle(GhostButtonStyle())
                    .help("装完 daemon 后点这里重新探测")
                Spacer()
            }
        }
        .padding(HVMSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
        .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
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
            .font(HVMFont.captionMedium)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, HVMSpace.buttonPadV7)
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

    @ViewBuilder
    private var importDiskField: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            HVMTextField(
                "/path/to/openwrt-arm64.qcow2",
                text: $importDiskPath,
                action: HVMTextField.ActionButton("Browse") { pickImportDisk() }
            )
            if let info = importDiskInfo {
                HStack(spacing: HVMSpace.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.accent)
                    Text("\(info.format.rawValue.uppercased()) · 虚拟容量 \(info.virtualSizeGiB) GiB · 后端将固定为 \(info.format == .qcow2 ? "QEMU" : "VZ")")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textSecondary)
                }
                Text("Disk 字段如填得更大将自动 resize; 不可缩小. 镜像会被拷贝进 bundle, 原文件保留.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let err = importDiskError {
                HStack(alignment: .top, spacing: HVMSpace.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.statusPaused)
                    Text(err)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("仅支持 qcow2 / raw 镜像 (例 OpenWrt / Debian cloud image / Alpine).")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
        }
    }

    private func pickImportDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // qcow2 / img / raw 没有标准 UTType, 放开 .data 让用户自由选, inspect 阶段再过滤
        panel.allowedContentTypes = [.diskImage, .data]
        if panel.runModal() == .OK, let url = panel.url {
            importDiskPath = url.path
            inspectImport(url)
        }
    }

    /// 调 DiskFactory.inspectImage 探测格式与虚拟容量, 失败时清掉 info 并把错误展示到 UI.
    private func inspectImport(_ url: URL) {
        importDiskInfo = nil
        importDiskError = nil
        guard let qemuImg = try? QemuPaths.qemuImgBinary() else {
            importDiskError = "qemu-img 不在包内 — 请先 make qemu (或 make build-all)"
            return
        }
        do {
            let info = try DiskFactory.inspectImage(at: url, qemuImg: qemuImg)
            importDiskInfo = info
            // 主盘 stepper 默认到镜像 virtual-size, 但不低于 stepper 的下限 (8 GiB)
            diskGiB = max(diskGiB, max(8, Int(info.virtualSizeGiB)))
        } catch let e as HVMError {
            importDiskError = e.userFacing.message + ": " + (e.userFacing.details["reason"] ?? "")
        } catch {
            importDiskError = "\(error)"
        }
    }

    private func resetImportState() {
        importDiskPath = ""
        importDiskInfo = nil
        importDiskError = nil
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

    /// 打开 Linux 发行版 / Win custom URL 镜像选择器. 用户选完 →
    /// AppModel 自动下载 + 进度条 + 校验, 完成后回填 isoPath.
    private func openOSImagePicker() {
        model.osImagePickerRequest = AppModel.OSImagePickerRequest(guestOS: guestOS) { localURL in
            self.isoPath = localURL.path
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
                                .font(HVMFont.caption)
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
                        .padding(.vertical, HVMSpace.buttonPadV7)
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
        // Win VM: 创建前确保 UTM Guest Tools ISO 就绪 (含 ARM64 native vdagent +
        // viogpudo + qemu-ga). 已缓存即立即继续; 否则前台 UtmGuestToolsFetchDialog
        // 模态进度. 失败 errors.present 不继续, user 可重试.
        // 注: virtio-win.iso 拉取已默认禁用; 后续若恢复, 在 windows 分支再串
        // model.startVirtioWinFetch(errors:) {...} 即可.
        if guestOS == .windows {
            model.startUtmGuestToolsFetch(errors: errors) {
                self.proceedWithBundleCreation()
            }
            return
        }
        proceedWithBundleCreation()
    }

    private func proceedWithBundleCreation() {
        do {
            // Linux 导入模式: 走 importDisk 分支 (跳过 ISO 校验, 不走装机)
            let isImport = (guestOS == .linux && creationSource == .importDisk)

            if isImport {
                guard let info = importDiskInfo, !importDiskPath.isEmpty else {
                    throw HVMError.config(.missingField(name: "导入磁盘镜像路径无效"))
                }
                // 防呆: 用户改的 disk 字段不可小于镜像虚拟容量
                if UInt64(diskGiB) < info.virtualSizeGiB {
                    throw HVMError.storage(.shrinkNotSupported(
                        currentBytes: Int64(info.virtualSizeBytes),
                        requestedBytes: Int64(diskGiB) * (1 << 30)
                    ))
                }
            } else {
                switch guestOS {
                case .linux, .windows: try ISOValidator.validate(at: isoPath)
                case .macOS:
                    guard FileManager.default.fileExists(atPath: ipswPath) else {
                        throw HVMError.install(.ipswNotFound(path: ipswPath))
                    }
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

            // UI 内部 NetworkChoice (.nat/.bridged/.shared) → 数据模型 NetworkMode 5-mode.
            // bridged 接口与 socket 路径派生由 NetworkSpec 字段承载, 不再嵌入 enum associated value.
            let netMode: NetworkMode
            var bridgedIface: String? = nil
            switch networkChoice {
            case .nat:
                netMode = .user
            case .bridged:
                guard !bridgedInterface.isEmpty else {
                    throw HVMError.config(.missingField(name: "network bridged 接口未选"))
                }
                netMode = .vmnetBridged
                bridgedIface = bridgedInterface
            case .shared:
                netMode = .vmnetShared
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
                networks: [NetworkSpec(
                    mode: netMode,
                    macAddress: MACAddressGenerator.random(),
                    bridgedInterface: bridgedIface
                )],
                installerISO: (isImport || guestOS == .macOS) ? nil : isoPath,
                bootFromDiskOnly: isImport,
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
            let mainDiskAbs = bundleURL.appendingPathComponent(mainDiskFile)
            if isImport, let info = importDiskInfo {
                do {
                    try DiskFactory.importImage(
                        from: URL(fileURLWithPath: importDiskPath),
                        to: mainDiskAbs,
                        info: info,
                        targetSizeGiB: UInt64(diskGiB),
                        qemuImg: qemuImg
                    )
                } catch {
                    // 导入失败回滚 bundle, 避免留下"半成品"目录
                    try? FileManager.default.removeItem(at: bundleURL)
                    throw error
                }
            } else {
                try DiskFactory.create(
                    at: mainDiskAbs,
                    sizeGiB: UInt64(diskGiB),
                    format: mainFormat,
                    qemuImg: qemuImg
                )
            }

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
