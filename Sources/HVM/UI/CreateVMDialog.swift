// CreateVMDialog.swift
// 创建向导 (M2 MVP: 单对话框). 按统一主题重写

import AppKit
import SwiftUI
import HVMBundle
import HVMCore
import HVMNet
import HVMStorage

struct CreateVMDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    @State private var name: String = ""
    @State private var cpu: Int = 4
    @State private var memoryGiB: Int = 4
    @State private var diskGiB: Int = 64
    @State private var isoPath: String = ""
    @State private var creating: Bool = false

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
                    osChip("Linux", selected: true)
                    osChip("macOS", selected: false, disabled: true)
                }
            }

            // CPU / Memory / Disk 三列
            HStack(spacing: HVMSpace.md) {
                field("CPU") {
                    stepperRow("\(cpu) cores", binding: $cpu, range: 1...16, step: 1)
                }
                field("Memory") {
                    stepperRow("\(memoryGiB) GB", binding: $memoryGiB, range: 1...128, step: 1)
                }
                field("Disk") {
                    stepperRow("\(diskGiB) GB", binding: $diskGiB, range: 8...2048, step: 8)
                }
            }

            field("Installer ISO") {
                HStack(spacing: HVMSpace.sm) {
                    TextField("/path/to/ubuntu-arm64.iso", text: $isoPath)
                        .textFieldStyle(.roundedBorder)
                        .font(HVMFont.body)
                    Button("Browse") { pickISO() }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            HStack(spacing: HVMSpace.md) {
                Spacer()
                Button("Cancel") { model.showCreateWizard = false }
                    .buttonStyle(GhostButtonStyle())
                Button("Create") { createAction() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(creating || name.isEmpty || isoPath.isEmpty)
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
    private func stepperRow(_ text: String, binding: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper("", value: binding, in: range, step: step)
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

    @ViewBuilder
    private func osChip(_ label: String, selected: Bool, disabled: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 6)
            .foregroundStyle(
                disabled ? HVMColor.textTertiary
                         : (selected ? HVMColor.textOnAccent : HVMColor.textSecondary)
            )
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(selected ? HVMColor.accent : HVMColor.bgBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .stroke(selected ? Color.clear : HVMColor.border, lineWidth: 1)
            )
            .help(disabled ? "M3 起支持 macOS guest" : "")
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

    private func createAction() {
        creating = true
        do {
            try ISOValidator.validate(at: isoPath)
            let config = VMConfig(
                displayName: name,
                guestOS: .linux,
                cpuCount: cpu,
                memoryMiB: UInt64(memoryGiB) * 1024,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: UInt64(diskGiB))],
                networks: [NetworkSpec(mode: .nat, macAddress: MACAddressGenerator.random())],
                installerISO: isoPath,
                bootFromDiskOnly: false,
                linux: LinuxSpec()
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
        } catch {
            errors.present(error)
        }
        creating = false
    }
}
