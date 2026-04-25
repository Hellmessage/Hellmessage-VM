// CreateVMDialog.swift
// 创建向导 (M2 MVP: 单对话框). 按统一主题重写

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HVMBundle
import HVMCore
import HVMNet
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

    /// 装机字段是否合法 (按 OS 分支)
    private var installerPathValid: Bool {
        switch guestOS {
        case .linux: return !isoPath.isEmpty
        case .macOS: return !ipswPath.isEmpty
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
                HStack(spacing: HVMSpace.sm) {
                    Button { guestOS = .linux } label: {
                        osChip("Linux", selected: guestOS == .linux)
                    }
                    .buttonStyle(.plain)

                    Button { guestOS = .macOS } label: {
                        osChip("macOS", selected: guestOS == .macOS)
                    }
                    .buttonStyle(.plain)
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

            // 装机源: Linux 走 ISO, macOS 走 IPSW
            switch guestOS {
            case .linux:
                field("Installer ISO") {
                    HStack(spacing: HVMSpace.sm) {
                        TextField("/path/to/ubuntu-arm64.iso", text: $isoPath)
                            .textFieldStyle(.roundedBorder)
                            .font(HVMFont.body)
                        Button("Browse") { pickISO() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            case .macOS:
                field("Installer IPSW") {
                    HStack(spacing: HVMSpace.sm) {
                        TextField("/path/to/UniversalMac_*.ipsw", text: $ipswPath)
                            .textFieldStyle(.roundedBorder)
                            .font(HVMFont.body)
                        Button("Browse") { pickIPSW() }
                            .buttonStyle(GhostButtonStyle())
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
    private func osChip(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? HVMColor.textOnAccent : HVMColor.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(selected ? HVMColor.accent : HVMColor.bgBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .stroke(selected ? Color.clear : HVMColor.border, lineWidth: 1)
            )
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
        do {
            // 装机源校验
            switch guestOS {
            case .linux: try ISOValidator.validate(at: isoPath)
            case .macOS:
                guard FileManager.default.fileExists(atPath: ipswPath) else {
                    throw HVMError.install(.ipswNotFound(path: ipswPath))
                }
            }

            let config = VMConfig(
                displayName: name,
                guestOS: guestOS,
                cpuCount: cpu,
                memoryMiB: UInt64(memoryGiB) * 1024,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: UInt64(diskGiB))],
                networks: [NetworkSpec(mode: .nat, macAddress: MACAddressGenerator.random())],
                installerISO: guestOS == .linux ? isoPath : nil,
                bootFromDiskOnly: false,
                macOS: guestOS == .macOS ? MacOSSpec(ipsw: ipswPath, autoInstalled: false) : nil,
                linux: guestOS == .linux ? LinuxSpec() : nil
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
