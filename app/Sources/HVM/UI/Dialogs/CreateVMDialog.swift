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
        }
        .onChange(of: guestOS) { _, _ in reloadCache() }
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

            // Windows 强制 QEMU 后端 + WindowsSpec 默认开 SecureBoot + TPM (Win11 必需)
            let engineValue: Engine
            let macOSSpec: MacOSSpec?
            let linuxSpec: LinuxSpec?
            let windowsSpec: WindowsSpec?
            switch guestOS {
            case .linux:
                engineValue = .vz; macOSSpec = nil; linuxSpec = LinuxSpec(); windowsSpec = nil
            case .macOS:
                engineValue = .vz
                macOSSpec = MacOSSpec(ipsw: ipswPath, autoInstalled: false)
                linuxSpec = nil; windowsSpec = nil
            case .windows:
                engineValue = .qemu; macOSSpec = nil; linuxSpec = nil
                windowsSpec = WindowsSpec()
            }

            let config = VMConfig(
                displayName: name,
                guestOS: guestOS,
                engine: engineValue,
                cpuCount: cpu,
                memoryMiB: UInt64(memoryGiB) * 1024,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: UInt64(diskGiB))],
                networks: [NetworkSpec(mode: .nat, macAddress: MACAddressGenerator.random())],
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
