// CreateVMDialog.swift
// 创建向导 (M2 MVP: 单对话框一页填所有参数, Linux only)
// 严格按 docs/GUI.md 弹窗约束: 只能通过 X 关闭, 遮罩不拦截

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
            // 遮罩禁止拦截
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶栏
                HStack {
                    Text("新建 VM")
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.95))
                    Spacer()
                    Button(action: { model.showCreateWizard = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(white: 0.8))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("w", modifiers: [.command])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color(white: 0.2))

                // 表单
                VStack(alignment: .leading, spacing: 14) {
                    labeled("名称") {
                        TextField("linux-vm", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeled("Guest OS") {
                        HStack(spacing: 10) {
                            osChip("Linux", selected: true)
                            osChip("macOS", selected: false, disabled: true)
                        }
                    }

                    HStack(spacing: 16) {
                        labeled("CPU 核心") {
                            Stepper("\(cpu)", value: $cpu, in: 1...16)
                                .labelsHidden()
                                .overlay(alignment: .leading) {
                                    Text("\(cpu) 核")
                                        .padding(.leading, 4)
                                        .foregroundStyle(Color(white: 0.85))
                                }
                        }
                        labeled("内存") {
                            Stepper("\(memoryGiB) GiB", value: $memoryGiB, in: 1...128)
                                .labelsHidden()
                                .overlay(alignment: .leading) {
                                    Text("\(memoryGiB) GiB")
                                        .padding(.leading, 4)
                                        .foregroundStyle(Color(white: 0.85))
                                }
                        }
                        labeled("主盘") {
                            Stepper("\(diskGiB) GiB", value: $diskGiB, in: 8...2048, step: 8)
                                .labelsHidden()
                                .overlay(alignment: .leading) {
                                    Text("\(diskGiB) GiB")
                                        .padding(.leading, 4)
                                        .foregroundStyle(Color(white: 0.85))
                                }
                        }
                    }

                    labeled("安装 ISO 路径") {
                        HStack {
                            TextField("/path/to/ubuntu-arm64.iso", text: $isoPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择...") { pickISO() }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("取消") { model.showCreateWizard = false }
                        Button("创建") { createAction() }
                            .buttonStyle(.borderedProminent)
                            .disabled(creating || name.isEmpty || isoPath.isEmpty)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .frame(width: 560)
            .background(Color(white: 0.08))
            .cornerRadius(10)
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 8)
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.6))
            content()
        }
    }

    @ViewBuilder
    private func osChip(_ label: String, selected: Bool, disabled: Bool = false) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                selected ? Color(red: 0.36, green: 0.55, blue: 1.0) : Color(white: 0.15)
            )
            .foregroundStyle(
                disabled ? Color(white: 0.4)
                         : (selected ? .white : Color(white: 0.85))
            )
            .cornerRadius(6)
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
