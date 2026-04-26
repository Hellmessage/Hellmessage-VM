// DetailBars.swift
// 从原 DetailPanel 拆出的 SwiftUI view, 供 AppKit DetailContainerView 通过 NSHostingView 嵌入.
//   - StoppedContentView: VM 停止时的整片详情 (title / resources / metadata / Start 按钮)
//   - DetailTopBar:       running 时的顶部栏 (GuestBadge + 名字 + 状态徽章)
//   - DetailBottomBar:    running 时的底部栏 (resource summary + Stop/Kill)
//   - StatusBadge:        状态胶囊 (圆点 + 文字), 在 dark 背景与彩色 banner 都用
// 保持与之前 DetailPanel 的视觉一致.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HVMBackend
import HVMBundle
import HVMCore
import HVMStorage

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

    /// 当前 session 的实时 state, 决定 PAUSE/RESUME 按钮显哪个
    private var sessionState: RunState {
        model.sessions[item.id]?.state ?? .stopped
    }

    var body: some View {
        HStack(spacing: HVMSpace.md) {
            Text("\(item.config.cpuCount)cpu · \(item.config.memoryMiB / 1024)gb · \(networkMode(item.config))")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()

            // PAUSE / RESUME 按 state 切换标签 (按钮排版: 动作破坏性递增)
            if case .paused = sessionState {
                Button("RESUME") {
                    Task {
                        do { try await model.resume(item.id) } catch { errors.present(error) }
                    }
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Button("PAUSE") {
                    Task {
                        do { try await model.pause(item.id) } catch { errors.present(error) }
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(sessionState != .running)
            }

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
    @Bindable var confirms: ConfirmPresenter
    let item: AppModel.VMListItem

    /// 当前 bundle 的 snapshot 列表. view init / 操作完成 / dialog 关闭后 reload.
    /// 不放 AppModel: snapshot 仅 stopped view 关心, 且无法跨进程通知 (文件级状态).
    @State private var snapshots: [SnapshotManager.Info] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HVMSpace.xl) {
                titleBlock
                resourcesSection
                metadataSection
                snapshotsSection
                actionRow
            }
            .padding(HVMSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HVMColor.bgBase)
        .onAppear { reloadSnapshots() }
        // 创建弹窗关闭后 reload (snapshotCreateItem nil 触发)
        .onChange(of: model.snapshotCreateItem?.id) { _, _ in
            reloadSnapshots()
        }
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
                // cpu / memory 可点 → 弹 EditConfigDialog (等价 hvm-cli config set)
                Button { model.editConfigItem = item } label: {
                    statCard(label: "cpu", value: "\(item.config.cpuCount)", unit: "cores", tint: HVMColor.statCPU)
                }
                .buttonStyle(.plain)
                .help("点击编辑 CPU 核数")

                Button { model.editConfigItem = item } label: {
                    statCard(label: "memory", value: "\(item.config.memoryMiB / 1024)", unit: "gb", tint: HVMColor.statMemory)
                }
                .buttonStyle(.plain)
                .help("点击编辑内存")

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

    // MARK: - Snapshots section

    /// VM 整体快照 (磁盘 + config), 基于 APFS clonefile.
    /// 入口: 顶部 + NEW 按钮; 行内 RESTORE / DELETE.
    /// 跟 hvm-cli snapshot 子命令完全等价, 都要求 VM stopped (BundleLock.isBusy 检测).
    private var snapshotsSection: some View {
        TerminalSection("Snapshots") {
            VStack(spacing: 0) {
                snapshotHeader
                if snapshots.isEmpty {
                    emptySnapshotRow
                } else {
                    snapshotRows
                }
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    private var snapshotHeader: some View {
        HStack(spacing: HVMSpace.md) {
            Text("\(snapshots.count) saved")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()
            Button {
                model.snapshotCreateItem = item
            } label: {
                Text("+ NEW")
            }
            .buttonStyle(GhostButtonStyle())
            .help("创建新快照 (clonefile, 几乎零空间)")
        }
        .padding(.horizontal, HVMSpace.md)
        .padding(.vertical, HVMSpace.sm)
    }

    private var emptySnapshotRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(HVMColor.border).frame(height: 1)
            HStack {
                Text("(无快照)")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
                Spacer()
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 12)
        }
    }

    private var snapshotRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.name) { _, info in
                Rectangle().fill(HVMColor.border).frame(height: 1)
                HStack(spacing: HVMSpace.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name)
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(Self.snapDateFmt.string(from: info.createdAt))
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                    Spacer()
                    Button("RESTORE") { restoreSnapshot(info.name) }
                        .buttonStyle(GhostButtonStyle())
                        .help("将磁盘和 config 还原到此快照 (覆盖当前)")
                    Button("DELETE") { deleteSnapshot(info.name) }
                        .buttonStyle(GhostButtonStyle(destructive: true))
                        .help("删除此快照")
                }
                .padding(.horizontal, HVMSpace.md)
                .padding(.vertical, 9)
            }
        }
    }

    private static let snapDateFmt: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private func reloadSnapshots() {
        snapshots = SnapshotManager.list(bundleURL: item.bundleURL)
    }

    private func restoreSnapshot(_ name: String) {
        confirms.present(ConfirmDialogModel(
            title: "还原快照",
            message: "将 \(item.displayName) 的磁盘和 config 还原到快照 \"\(name)\"。当前 disks/* 与 config 会被覆盖,且不可撤销。",
            confirmTitle: "还原",
            cancelTitle: "取消",
            destructive: true
        )) { confirmed in
            guard confirmed else { return }
            do {
                if BundleLock.isBusy(bundleURL: item.bundleURL) {
                    throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
                }
                try SnapshotManager.restore(bundleURL: item.bundleURL, name: name)
                model.refreshList()
                reloadSnapshots()
            } catch {
                errors.present(error)
            }
        }
    }

    private func deleteSnapshot(_ name: String) {
        confirms.present(ConfirmDialogModel(
            title: "删除快照",
            message: "确定删除快照 \"\(name)\"? 此操作不可撤销。",
            confirmTitle: "删除",
            cancelTitle: "取消",
            destructive: true
        )) { confirmed in
            guard confirmed else { return }
            do {
                try SnapshotManager.delete(bundleURL: item.bundleURL, name: name)
                reloadSnapshots()
            } catch {
                errors.present(error)
            }
        }
    }

    /// boot 字段文案: macOS guest 装机阶段不挂 ISO 而是 IPSW + VZMacOSInstaller, 文案与 Linux 区分
    private var bootModeLabel: String {
        if item.config.bootFromDiskOnly { return "from disk" }
        switch item.guestOS {
        case .linux, .windows: return "from iso (installer mode)"
        case .macOS:           return "from ipsw (installer mode)"
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

            // ISO 切换 (仅 Linux). 等价 hvm-cli iso select / eject
            if item.guestOS == .linux {
                Button(item.config.installerISO != nil ? "CHANGE ISO" : "SELECT ISO") {
                    selectIsoAction()
                }
                .buttonStyle(GhostButtonStyle())
                .help("挂载 / 替换安装 ISO (会自动取消 bootFromDiskOnly)")

                if item.config.installerISO != nil {
                    Button("EJECT ISO") { ejectIsoAction() }
                        .buttonStyle(GhostButtonStyle())
                        .help("弹出 ISO 并切到仅硬盘启动")
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

    private func selectIsoAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.installerISO = url.path
            config.bootFromDiskOnly = false
            try BundleIO.save(config: config, to: item.bundleURL)
            model.refreshList()
        } catch {
            errors.present(error)
        }
    }

    private func ejectIsoAction() {
        do {
            if BundleLock.isBusy(bundleURL: item.bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: item.bundleURL)
            config.installerISO = nil
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
// 终端启动屏: ASCII banner + boot log (host 能力探测) + 大号 CTA
// 同时覆盖两种语义: ① VM 列表为空 → 引导新建 ② 列表非空但没选 → 引导左侧选择

struct DetailEmptyState: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: HVMSpace.xl)

            asciiBanner

            Text("// virtualization terminal")
                .font(HVMFont.caption)
                .tracking(2.4)
                .foregroundStyle(HVMColor.textTertiary)
                .padding(.top, HVMSpace.md)

            bootLog
                .padding(.top, HVMSpace.xl)

            cta
                .padding(.top, HVMSpace.xl)

            Spacer(minLength: HVMSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HVMColor.bgBase)
    }

    // MARK: banner

    private var asciiBanner: some View {
        Text(Self.banner)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(HVMColor.accent)
            .shadow(color: HVMColor.accent.opacity(0.45), radius: 10)
            .lineSpacing(0)
            .fixedSize()
    }

    // MARK: boot log

    private var bootLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            bootLine(label: "vz",     value: "ready",                ok: true)
            bootLine(label: "host",   value: HostProbe.cpuBrand,     ok: true)
            bootLine(label: "cores",  value: "\(HostProbe.cpuCount)", ok: true)
            bootLine(label: "memory", value: HostProbe.memoryString, ok: true)
            bootLine(label: "guests", value: "macos · linux",        ok: true)
        }
        .padding(HVMSpace.lg)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    private func bootLine(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: HVMSpace.sm) {
            Text(ok ? "[ ok ]" : "[ -- ]")
                .font(HVMFont.caption)
                .foregroundStyle(ok ? HVMColor.statusRunning : HVMColor.textTertiary)
            Text(label.padding(toLength: 7, withPad: " ", startingAt: 0))
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textSecondary)
            Text(value)
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: 360, alignment: .leading)
    }

    // MARK: CTA

    @ViewBuilder
    private var cta: some View {
        if model.list.isEmpty {
            VStack(spacing: HVMSpace.sm) {
                Button(action: { model.showCreateWizard = true }) {
                    Text("[ + NEW VM ]")
                }
                .buttonStyle(HeroCTAStyle())

                Text("press ⌘N or click + NEW above")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
        } else {
            VStack(spacing: HVMSpace.xs) {
                Text("// \(model.list.count) vm\(model.list.count == 1 ? "" : "s") in registry")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                Text("← select one on the left")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
            }
        }
    }

    // 28 列宽 ANSI block banner
    private static let banner = """
    ██╗  ██╗██╗   ██╗███╗   ███╗
    ██║  ██║██║   ██║████╗ ████║
    ███████║██║   ██║██╔████╔██║
    ██╔══██║╚██╗ ██╔╝██║╚██╔╝██║
    ██║  ██║ ╚████╔╝ ██║ ╚═╝ ██║
    ╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝
    """
}

// MARK: - host 能力探测 (只读, 无 entitlement)

private enum HostProbe {
    static let cpuBrand: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let payload = bytes.firstIndex(of: 0).map { bytes.prefix($0) } ?? bytes.prefix(bytes.count)
        return String(decoding: payload, as: UTF8.self)
    }()

    static let cpuCount: Int = ProcessInfo.processInfo.processorCount

    static let memoryString: String = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return String(format: "%.0f gb", gb)
    }()
}
