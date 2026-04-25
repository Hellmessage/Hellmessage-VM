// DetailBars.swift
// 从原 DetailPanel 拆出的 SwiftUI view, 供 AppKit DetailContainerView 通过 NSHostingView 嵌入.
//   - StoppedContentView: VM 停止时的整片详情 (title / resources / metadata / Start 按钮)
//   - DetailTopBar:       running 时的顶部栏 (GuestBadge + 名字 + 状态徽章)
//   - DetailBottomBar:    running 时的底部栏 (resource summary + Stop/Kill)
//   - StatusBadge:        状态胶囊 (圆点 + 文字), 在 dark 背景与彩色 banner 都用
// 保持与之前 DetailPanel 的视觉一致.

import AppKit
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore

// MARK: - 状态徽章 (公共)

struct StatusBadge: View {
    let state: RunState
    var onDark: Bool = false

    var body: some View {
        let (label, color) = labelColor
        HStack(spacing: 5) {
            if case .running = state {
                PulseDot(color: onDark ? Color.white.opacity(0.9) : color, size: 5)
            } else {
                Text("●")
                    .font(.system(size: 8))
                    .foregroundStyle(onDark ? Color.white.opacity(0.85) : color)
            }
            Text(label.uppercased())
                .font(HVMFont.label)
                .tracking(0.8)
                .foregroundStyle(onDark ? Color.white : color)
        }
        .padding(.horizontal, onDark ? 10 : 0)
        .padding(.vertical, onDark ? 4 : 0)
        .background(
            Group {
                if onDark {
                    Capsule().fill(Color.black.opacity(0.28))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
            }
        )
    }

    private var labelColor: (String, Color) {
        switch state {
        case .stopped: return ("stopped", HVMColor.statusStopped)
        case .starting: return ("starting", HVMColor.statusPaused)
        case .running: return ("running", HVMColor.statusRunning)
        case .paused: return ("paused", HVMColor.statusPaused)
        case .stopping: return ("stopping", HVMColor.statusPaused)
        case .error: return ("error", HVMColor.statusError)
        }
    }
}

// MARK: - Running 顶栏

struct DetailTopBar: View {
    @Bindable var model: AppModel
    let item: AppModel.VMListItem

    var body: some View {
        let session = model.sessions[item.id]
        HStack(spacing: HVMSpace.md) {
            GuestBadge(os: item.guestOS, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(HVMFont.heading)
                    .foregroundStyle(HVMColor.textPrimary)
                StatusBadge(state: session?.state ?? .starting)
            }
            Spacer()
        }
        .padding(.horizontal, HVMSpace.xl)
        .padding(.vertical, HVMSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HVMColor.bgSidebar)
    }
}

// MARK: - Running 底栏

struct DetailBottomBar: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    var body: some View {
        HStack(spacing: HVMSpace.md) {
            Text("\(item.config.cpuCount)cpu · \(item.config.memoryMiB / 1024)gb · \(networkMode(item.config))")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()
            Button("STOP") {
                do { try model.stop(item.id) } catch { errors.present(error) }
            }
            .buttonStyle(GhostButtonStyle())

            Button("KILL") {
                Task {
                    do { try await model.kill(item.id) } catch { errors.present(error) }
                }
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
        }
        .padding(.horizontal, HVMSpace.xl)
        .padding(.vertical, HVMSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HVMColor.bgSidebar)
    }

    private func networkMode(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "—" }
        switch net.mode {
        case .nat: return "nat"
        case .bridged: return "bridged"
        }
    }
}

// MARK: - Stopped 整片内容

struct StoppedContentView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HVMSpace.xl) {
                titleBlock
                resourcesSection
                metadataSection
                actionRow
            }
            .padding(HVMSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HVMColor.bgBase)
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: HVMSpace.lg) {
            GuestBadge(os: item.guestOS, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .font(HVMFont.hero)
                    .foregroundStyle(HVMColor.textPrimary)
                HStack(spacing: HVMSpace.sm) {
                    StatusBadge(state: .stopped)
                    Text("·")
                        .foregroundStyle(HVMColor.textTertiary)
                    Text(GuestVisual.style(for: item.guestOS).label)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.bundleURL])
            } label: {
                Text("REVEAL")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Show in Finder")

            Button(role: .destructive) { deleteAction() } label: {
                Text("DELETE")
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
            .help("Move to Trash")
        }
    }

    private var resourcesSection: some View {
        TerminalSection("Resources") {
            HStack(spacing: HVMSpace.md) {
                statCard(label: "cpu", value: "\(item.config.cpuCount)", unit: "cores", tint: HVMColor.statCPU)
                statCard(label: "memory", value: "\(item.config.memoryMiB / 1024)", unit: "gb", tint: HVMColor.statMemory)
                statCard(label: "disk", value: "\(item.config.disks.first?.sizeGiB ?? 0)", unit: "gb", tint: HVMColor.statDisk)
                statCard(label: "network", value: networkMode(item.config).lowercased(), unit: nil, tint: HVMColor.statNetwork)
            }
        }
    }

    @ViewBuilder
    private func statCard(label: String, value: String, unit: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            Text(label.uppercased())
                .font(HVMFont.label)
                .tracking(1.5)
                .foregroundStyle(tint.opacity(0.85))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(HVMFont.statValue)
                    .foregroundStyle(HVMColor.textPrimary)
                if let unit {
                    Text(unit)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textTertiary)
                }
            }
        }
        .padding(HVMSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgCard))
        .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
    }

    private var metadataSection: some View {
        TerminalSection("Metadata") {
            VStack(spacing: 0) {
                kvRow("id",     item.config.id.uuidString.lowercased(), truncating: true, first: true)
                kvRow("mac",    item.config.networks.first?.macAddress ?? "—")
                if item.guestOS == .macOS {
                    kvRow("ipsw",      item.config.macOS?.ipsw ?? "—", truncating: true)
                    kvRow("installed", item.config.macOS?.autoInstalled == true ? "yes (auto)" : "no — run install")
                } else {
                    kvRow("iso", item.config.installerISO ?? "—", truncating: true)
                }
                kvRow("boot",   bootModeLabel)
                kvRow("bundle", item.bundleURL.path, truncating: true, last: true)
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    /// boot 字段文案: macOS guest 装机阶段不挂 ISO 而是 IPSW + VZMacOSInstaller, 文案与 Linux 区分
    private var bootModeLabel: String {
        if item.config.bootFromDiskOnly { return "from disk" }
        switch item.guestOS {
        case .linux: return "from iso (installer mode)"
        case .macOS: return "from ipsw (installer mode)"
        }
    }

    @ViewBuilder
    private func kvRow(_ key: String, _ value: String,
                       truncating: Bool = false,
                       first: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle().fill(HVMColor.border).frame(height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: HVMSpace.md) {
                Text(key)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .frame(width: 64, alignment: .leading)
                Text("=")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                if truncating {
                    Text(value)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(value)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 9)
        }
    }

    private var actionRow: some View {
        HStack(spacing: HVMSpace.md) {
            if needsInstall {
                // macOS guest 未装机: 主按钮换成 INSTALL, 跑 VZMacOSInstaller
                Button(action: installAction) {
                    HStack(spacing: 6) {
                        Text("⏬").font(.system(size: 10))
                        Text("INSTALL")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(item.config.macOS?.ipsw == nil)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("跑 VZMacOSInstaller 装 macOS 到主盘. 装完 autoInstalled=true 后此按钮变为 START")
            } else {
                Button(action: startAction) {
                    HStack(spacing: 6) {
                        Text("▶").font(.system(size: 10))
                        Text("START")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])

                // 装机模式 (Linux 有 ISO 且 bootFromDiskOnly=false) 才显示. 切完按钮隐藏.
                // 等价 hvm-cli boot-from-disk 子命令 (Sources/hvm-cli/Commands/BootFromDiskCommand.swift)
                if item.config.installerISO != nil && !item.config.bootFromDiskOnly {
                    Button(action: bootFromDiskAction) {
                        Text("BOOT FROM DISK")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .help("装完 OS 后切到只从硬盘启动, 下次开机不挂 ISO")
                }
            }
        }
    }

    /// macOS guest 未装机才需要 INSTALL 按钮. Linux 走 start + boot-from-disk 链.
    private var needsInstall: Bool {
        item.guestOS == .macOS && item.config.macOS?.autoInstalled != true
    }

    private func startAction() {
        Task {
            do { try await model.start(item) } catch { errors.present(error) }
        }
    }

    private func installAction() {
        guard let ipsw = item.config.macOS?.ipsw else {
            errors.present(HVMError.config(.missingField(name: "macOS.ipsw")))
            return
        }
        model.startInstall(
            bundleURL: item.bundleURL,
            config: item.config,
            ipswURL: URL(fileURLWithPath: ipsw),
            errors: errors
        )
    }

    private func bootFromDiskAction() {
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.bootFromDiskOnly = true
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
        } catch {
            errors.present(error)
        }
    }

    private func deleteAction() {
        do {
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: item.bundleURL, resultingItemURL: &resultURL)
            model.refreshList()
        } catch {
            errors.present(error)
        }
    }

    private func networkMode(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "—" }
        switch net.mode {
        case .nat: return "NAT"
        case .bridged: return "Bridged"
        }
    }
}

// MARK: - 空状态 (未选中 VM)

struct DetailEmptyState: View {
    var body: some View {
        VStack(spacing: HVMSpace.sm) {
            Text("/*")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textTertiary)
            Text("select a vm on the left")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textSecondary)
            Text("*/")
                .font(HVMFont.body)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HVMColor.bgBase)
    }
}
