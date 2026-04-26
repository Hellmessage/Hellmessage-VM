// CreateVMDialog.swift
// 创建向导 (M2 MVP: 单对话框). 按统一主题重写

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
    /// IPSW cache 列表; 切到 macOS 分支时刷新, Use Latest / fetch 完成后刷新
    @State private var ipswCache: [IPSWCacheItem] = []
    /// 进入向导时探测一次 QEMU 后端是否就绪 (third_party/qemu 或 .app/Contents/Resources/QEMU);
    /// 不可用时 Windows 按钮 disabled, 给清晰的"先 make qemu"提示
    @State private var qemuBackendAvailable: Bool = false
    /// Linux 专用: 引擎选择 (macOS=vz / Windows=qemu 强制, 不暴露)
    @State private var linuxEngine: Engine = .vz
    /// 网络模式 (NAT / Bridged / Shared); .bridged/.shared 仅 effectiveEngine == .qemu 可选
    @State private var networkChoice: NetworkChoice = .nat
    /// bridged 模式选定接口 (默认空字符串, picker 渲染时初始化)
    @State private var bridgedInterface: String = ""
    /// host 上检测到的可桥接接口 (en0, en1, ...). 选 .bridged 时刷新一次
    @State private var availableInterfaces: [VmnetSetupHelper.InterfaceInfo] = []
    /// 当前 daemon 是否就绪 (按选中模式 + 选中接口); onAppear / 模式切换 / 接口切换重新探测
    @State private var daemonReady: Bool = false
    /// osascript 引导失败时返回的命令字符串, 显示在卡片里供用户复制
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

    /// 当前实际生效的 engine. macOS 强制 vz, windows 强制 qemu, linux 跟随用户选择
    private var effectiveEngine: Engine {
        switch guestOS {
        case .macOS:   return .vz
        case .windows: return .qemu
        case .linux:   return linuxEngine
        }
    }

    /// .bridged / .shared 是否可选: 仅 QEMU 后端 (socket_vmnet sidecar)
    private var vmnetModesEnabled: Bool {
        effectiveEngine == .qemu
    }

    /// 装机字段是否合法 (按 OS 分支)
    private var installerPathValid: Bool {
        switch guestOS {
        case .linux, .windows: return !isoPath.isEmpty
        case .macOS:           return !ipswPath.isEmpty
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Divider().background(HVMColor.border)
                form
            }
            .frame(width: 520)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
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
        // banner 完成态消失也意味着 cache 可能新增, 跟着刷
        .onChange(of: model.ipswFetchState == nil) { _, _ in reloadCache() }
    }

    private var header: some View {
        HStack(spacing: HVMSpace.md) {
            Text("Create Virtual Machine")
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
            Spacer()
            Button { model.showCreateWizard = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("w", modifiers: [.command])
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            field("Name") {
                TextField("linux-vm", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(HVMFont.body)
            }

            field("Guest OS") {
                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    HStack(spacing: HVMSpace.sm) {
                        Button { guestOS = .linux } label: {
                            osChip("Linux", selected: guestOS == .linux, disabled: false)
                        }
                        .buttonStyle(.plain)

                        Button { guestOS = .macOS } label: {
                            osChip("macOS", selected: guestOS == .macOS, disabled: false)
                        }
                        .buttonStyle(.plain)

                        Button { guestOS = .windows } label: {
                            osChip("Windows", selected: guestOS == .windows,
                                   disabled: !qemuBackendAvailable)
                        }
                        .buttonStyle(.plain)
                        .disabled(!qemuBackendAvailable)
                        .help(qemuBackendAvailable
                              ? "实验性: Windows arm64 走 QEMU 后端"
                              : "Windows 需要 QEMU 后端: 请先 make qemu (或 make build-all)")
                    }
                    if guestOS == .windows {
                        Text("// 实验性: Windows arm64 走 QEMU 后端 (强制 engine=qemu)")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textTertiary)
                    } else if !qemuBackendAvailable {
                        Text("// Windows 暂不可选 — third_party/qemu 未就绪 (需先 make qemu)")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }

            // Engine: Linux 时显示选项 (VZ / QEMU); macOS / Windows 锁死
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
                              ? "QEMU 后端: 支持 socket_vmnet 桥接/共享网络"
                              : "QEMU 暂不可选 — 需先 make qemu (或 make build-all)")
                        Spacer()
                    }
                }
            }

            // CPU / Memory / Disk 三列
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

            // 装机源: Linux/Windows 走 ISO, macOS 走 IPSW
            switch guestOS {
            case .linux, .windows:
                field("Installer ISO") {
                    HStack(spacing: HVMSpace.sm) {
                        TextField(guestOS == .windows
                                  ? "/path/to/Win11_arm64.iso"
                                  : "/path/to/ubuntu-arm64.iso",
                                  text: $isoPath)
                            .textFieldStyle(.roundedBorder)
                            .font(HVMFont.body)
                        Button("Browse") { pickISO() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            case .macOS:
                field("Installer IPSW") {
                    VStack(alignment: .leading, spacing: HVMSpace.xs) {
                        HStack(spacing: HVMSpace.sm) {
                            TextField("/path/to/UniversalMac_*.ipsw", text: $ipswPath)
                                .textFieldStyle(.roundedBorder)
                                .font(HVMFont.body)
                            Button("Browse") { pickIPSW() }
                                .buttonStyle(GhostButtonStyle())
                        }
                        HStack(spacing: HVMSpace.sm) {
                            Button("Use Latest") { fetchLatestIPSW() }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(creating || model.ipswFetchState != nil)
                                .help("拉 Apple 推荐的最新 IPSW (VZMacOSRestoreImage.fetchLatestSupported)")
                            Button("Choose Version…") { openCatalogPicker() }
                                .buttonStyle(GhostButtonStyle())
                                .disabled(creating || model.ipswFetchState != nil)
                                .help("打开 Apple catalog, 选择具体的 macOS 版本下载")
                            Spacer()
                        }
                        // 已缓存 IPSW 一键填入. cache 为空时不显示, 不堆积视觉噪音.
                        if !ipswCache.isEmpty {
                            cachePicker
                        }
                        Text("// 大约 10-15 GiB. 已缓存的 build 不会重复下载.")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }

            HStack(spacing: HVMSpace.md) {
                Spacer()
                Button("Cancel") { model.showCreateWizard = false }
                    .buttonStyle(GhostButtonStyle())
                Button(guestOS == .macOS ? "Create & Install" : "Create") { createAction() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(creating || name.isEmpty || !installerPathValid)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.top, HVMSpace.xs)
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

    /// 网络段: NAT 任意 engine; bridged/shared 仅 QEMU 后端 (走 socket_vmnet 系统级 daemon).
    /// 选 bridged 时下挂接口 picker; 选 bridged/shared 且对应 daemon 未跑时显示提示卡片.
    @ViewBuilder
    private var networkSection: some View {
        field("Network") {
            VStack(alignment: .leading, spacing: HVMSpace.md) {
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
                    Text("// Bridged / Shared 仅 QEMU 后端可选 (VZ bridged 等 Apple entitlement 审批)")
                        .font(HVMFont.caption)
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
        case .nat: return "QEMU SLIRP / VZ NAT: 默认网络, guest 可出网, host 与 guest 单向"
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
            Text("// 未检测到可用接口 (要求 IFF_UP & IFF_RUNNING + 非 lo / utun / awdl)")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        } else {
            HVMFormSelect(
                options: availableInterfaces.map { (value: $0.name, label: $0.displayName) },
                selection: $bridgedInterface,
                accessibilityLabel: "网卡"
            )
        }
    }

    /// 当前网络模式对应的 daemon 是否就绪. networkChoice / bridgedInterface 改变时刷新.
    private func refreshDaemonReady() {
        switch networkChoice {
        case .nat:     daemonReady = true   // NAT 不需 daemon
        case .bridged: daemonReady = bridgedInterface.isEmpty
            ? false
            : VmnetSetupHelper.daemonReady(.bridged(interface: bridgedInterface))
        case .shared:  daemonReady = VmnetSetupHelper.daemonReady(.shared)
        }
    }

    /// daemon 未跑时的提示卡片. 主按钮跑 osascript→Terminal sudo bash <script> [iface];
    /// 失败 fallback 到命令字符串复制.
    @ViewBuilder
    private var daemonHelperCard: some View {
        let modeLabel = (networkChoice == .bridged) ? "bridged(\(bridgedInterface))" : "shared"
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            Text("⚠ socket_vmnet \(modeLabel) daemon 未跑")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textPrimary)
            Text("一次 sudo 装 launchd daemon, 之后所有 VM 启动 / 关闭 不再 sudo. 详见 scripts/install-vmnet-helper.sh.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
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
                    .help("跑完脚本后点这里重新探测对应 socket")
                Spacer()
            }
            if let cmd = helperFallbackCommand {
                Text(cmd)
                    .font(HVMFont.small.monospaced())
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)
                    .padding(HVMSpace.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: HVMRadius.sm).fill(HVMColor.bgBase))
            }
        }
        .padding(HVMSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HVMRadius.sm).fill(HVMColor.bgCard))
        .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm).stroke(HVMColor.border, lineWidth: 1))
    }

    private func runDaemonHelper() {
        // bridged 时把接口名作为脚本参数传 (脚本约定: 不带参 → 装 shared+host; 带 ifaceName → 加桥接)
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

    @ViewBuilder
    private func stepperRow(unit: String, binding: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(spacing: 4) {
            TextField("", value: clampedBinding(binding, range: range), formatter: Self.integerFormatter)
                .textFieldStyle(.plain)
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(unit)
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textSecondary)
            Stepper("", value: clampedBinding(binding, range: range), in: range, step: step)
                .labelsHidden()
        }
        .padding(.horizontal, HVMSpace.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .fill(HVMColor.bgBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    /// 用户手动输入超范围时 set 时 clamp 回 range. NumberFormatter 自带 min/max 会让 SwiftUI
    /// 在 commit 时拒绝设置, 输入框停在脏值; 走 clamped binding 体验更顺.
    private func clampedBinding(_ source: Binding<Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { source.wrappedValue },
            set: { source.wrappedValue = max(range.lowerBound, min(range.upperBound, $0)) }
        )
    }

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    @ViewBuilder
    private func osChip(_ label: String, selected: Bool, disabled: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 6)
            .foregroundStyle(disabled
                             ? HVMColor.textTertiary
                             : (selected ? HVMColor.textOnAccent : HVMColor.textSecondary))
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(selected ? HVMColor.accent : HVMColor.bgBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
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

    /// 走 IPSWFetcher 拉 Apple 最新 IPSW. 期间 IpswFetchDialog 显示进度模态.
    /// 完成后回填 ipswPath, 同时刷新 cache 列表.
    private func fetchLatestIPSW() {
        model.startIpswFetch(errors: errors) { localURL in
            self.ipswPath = localURL.path
            self.reloadCache()
        }
    }

    /// 弹 IPSW catalog picker, 用户挑一个 build 后走 startIpswFetch(entry:) 下载.
    /// picker / fetch dialog / 向导是一条链条, 都覆盖在向导之上 (DialogOverlay 顺序).
    private func openCatalogPicker() {
        model.ipswCatalogPicker = AppModel.IpswCatalogPickerState { entry in
            // 选完触发 fetch; fetch 完成回填 ipswPath
            model.startIpswFetch(entry: entry, errors: errors) { localURL in
                self.ipswPath = localURL.path
                self.reloadCache()
            }
        }
    }

    private func reloadCache() {
        ipswCache = IPSWFetcher.listCache()
    }

    /// 已缓存 IPSW 一键填入. 一行一个 build, 显示大小; 点击即把 ipswPath 设为该路径.
    @ViewBuilder
    private var cachePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText("Cached IPSW", color: HVMColor.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(ipswCache.enumerated()), id: \.element.buildVersion) { idx, item in
                    if idx > 0 { Rectangle().fill(HVMColor.border).frame(height: 1) }
                    Button {
                        ipswPath = item.path
                    } label: {
                        HStack(spacing: HVMSpace.sm) {
                            Image(systemName: ipswPath == item.path ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(ipswPath == item.path ? HVMColor.accent : HVMColor.textTertiary)
                            Text(item.buildVersion)
                                .font(HVMFont.bodyBold)
                                .foregroundStyle(HVMColor.textPrimary)
                            Text(formatCacheSize(item.sizeBytes))
                                .font(HVMFont.caption)
                                .foregroundStyle(HVMColor.textTertiary)
                                .monospacedDigit()
                            Spacer()
                            Text(item.path)
                                .font(HVMFont.caption)
                                .foregroundStyle(HVMColor.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, HVMSpace.sm)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.sm).fill(HVMColor.bgBase))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm).stroke(HVMColor.border, lineWidth: 1))
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
        // Apple 给 .ipsw 注册了 com.apple.itunes.ipsw, 但不一定都能识别. 兜底 .data 让用户能选到.
        let ipswType = UTType("com.apple.itunes.ipsw") ?? .data
        panel.allowedContentTypes = [ipswType, .data]
        if panel.runModal() == .OK, let url = panel.url {
            ipswPath = url.path
        }
    }

    private func createAction() {
        creating = true
        // Windows + virtio-win 未缓存: 先前台下载 (~700MB modal), 完成后再走 bundle 创建.
        // 若已缓存 startVirtioWinFetch 内部会立即 onComplete 不弹 dialog.
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
            // 装机源校验
            switch guestOS {
            case .linux, .windows: try ISOValidator.validate(at: isoPath)
            case .macOS:
                guard FileManager.default.fileExists(atPath: ipswPath) else {
                    throw HVMError.install(.ipswNotFound(path: ipswPath))
                }
            }

            // engine: Windows 强制 qemu, macOS 强制 vz, Linux 跟随 linuxEngine 选择
            // network: NAT 任意 engine; bridged/shared 仅 effectiveEngine == .qemu (走 socket_vmnet sidecar)
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

            let config = VMConfig(
                displayName: name,
                guestOS: guestOS,
                engine: engineValue,
                cpuCount: cpu,
                memoryMiB: UInt64(memoryGiB) * 1024,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: UInt64(diskGiB))],
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
            try DiskFactory.create(
                at: BundleLayout.mainDiskURL(bundleURL),
                sizeGiB: UInt64(diskGiB)
            )

            // Win VM (QEMU 双 pflash) 必须 RW NVRAM vars 文件; 从 EDK2 vars 模板拷贝.
            // 模板由 make qemu 下载到 .app/Resources/QEMU/share/qemu/edk2-aarch64-vars.fd; 缺则 host 启动时兜底再拷.
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

            // macOS: 创建 bundle 完成后立刻进入装机模态. installState 更新触发 InstallDialog 显示.
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
