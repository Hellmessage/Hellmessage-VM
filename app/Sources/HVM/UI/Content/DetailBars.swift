// DetailBars.swift
// 右栏详情区的 SwiftUI views, 给 AppKit DetailContainerView 通过 NSHostingView 嵌入.
//   - DetailEmptyState:   未选中 VM 的占位
//   - StoppedContentView: 选中 stopped VM 的整片详情
//   - DetailTopBar:       running 顶栏
//   - DetailBottomBar:    running 底栏
//   - StatusBadge:        通用状态徽章
// 视觉: 专业工具风, 卡片化分组, 蓝 accent.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HVMBackend
import HVMBundle
import HVMCore
import HVMStorage

// MARK: - 状态徽章

struct StatusBadge: View {
    let state: RunState
    var onDark: Bool = false

    var body: some View {
        let (label, color) = labelColor
        HStack(spacing: 5) {
            if case .running = state {
                Circle()
                    .fill(onDark ? Color.white.opacity(0.95) : color)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(onDark ? Color.white.opacity(0.85) : color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(HVMFont.small.weight(.semibold))
                .foregroundStyle(onDark ? Color.white : color)
        }
        .padding(.horizontal, onDark ? 10 : 0)
        .padding(.vertical, onDark ? 4 : 0)
        .background(
            Group {
                if onDark {
                    Capsule().fill(Color.black.opacity(0.30))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
            }
        )
    }

    private var labelColor: (String, Color) {
        switch state {
        case .stopped:  return ("Stopped", HVMColor.statusStopped)
        case .starting: return ("Starting", HVMColor.statusPaused)
        case .running:  return ("Running", HVMColor.statusRunning)
        case .paused:   return ("Paused", HVMColor.statusPaused)
        case .stopping: return ("Stopping", HVMColor.statusPaused)
        case .error:    return ("Error", HVMColor.statusError)
        }
    }
}

// MARK: - Running 顶栏

struct DetailTopBar: View {
    @Bindable var model: AppModel
    let item: AppModel.VMListItem

    var body: some View {
        let session = model.sessions[item.id]
        // QEMU 后端走 host 子进程, 主 GUI 无本地 session — fallback 到 item.runState
        // (model.list 里来自 BundleLock 探测) 而不是死写 .starting.
        let displayState = session?.state ?? (item.runState == "running" ? .running : .stopped)
        HStack(spacing: HVMSpace.md) {
            GuestBadge(os: item.guestOS, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(HVMFont.title)
                    .foregroundStyle(HVMColor.textPrimary)
                StatusBadge(state: displayState)
            }
            Spacer()
            // QEMU 后端独立窗口 toggle: 仅 .qemu engine + running 时显示.
            // 共存式 (CLAUDE.md / 设计决策): 主窗口嵌入 + detached 独立窗口可同时存在.
            if item.config.engine == .qemu, displayState == .running {
                let detached = model.detachedQemuVMs.contains(item.id)
                Button {
                    model.toggleDetachedQemu(id: item.id)
                } label: {
                    Image(systemName: detached
                          ? "rectangle.on.rectangle.fill"
                          : "rectangle.on.rectangle")
                }
                .buttonStyle(IconButtonStyle())
                .help(detached ? "关闭独立窗口" : "弹出到独立窗口")
            }
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

    private var sessionState: RunState {
        // QEMU 后端走 host 子进程, 主 GUI 无本地 session — fallback 走 item.runState
        if let s = model.sessions[item.id]?.state { return s }
        return item.runState == "running" ? .running : .stopped
    }

    var body: some View {
        HStack(spacing: HVMSpace.md) {
            Text("\(item.config.cpuCount) cores · \(item.config.memoryMiB / 1024) GB · \(networkMode(item.config))")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()

            if case .paused = sessionState {
                Button("Resume") {
                    Task { do { try await model.resume(item.id) } catch { errors.present(error) } }
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Button("Pause") {
                    Task { do { try await model.pause(item.id) } catch { errors.present(error) } }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(sessionState != .running)
            }

            Button("Stop") {
                do { try model.stop(item.id) } catch { errors.present(error) }
            }
            .buttonStyle(GhostButtonStyle())

            Button("Kill") {
                Task { do { try await model.kill(item.id) } catch { errors.present(error) } }
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
        case .nat:     return "NAT"
        case .bridged: return "Bridged"
        case .shared:  return "Shared"
        }
    }
}

// MARK: - Stopped 整片内容

struct StoppedContentView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    @Bindable var confirms: ConfirmPresenter
    let item: AppModel.VMListItem

    @State private var snapshots: [SnapshotManager.Info] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HVMSpace.xl) {
                titleBlock
                resourcesSection
                metadataSection
                disksSection
                snapshotsSection
                actionRow
            }
            .padding(HVMSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HVMColor.bgBase)
        .onAppear { reloadSnapshots() }
        .onChange(of: model.snapshotCreateItem?.id) { _, _ in
            reloadSnapshots()
        }
    }

    // MARK: title

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: HVMSpace.md) {
            GuestBadge(os: item.guestOS, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(HVMFont.title)
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
                Text("Reveal")
            }
            .buttonStyle(GhostButtonStyle())
            .help("Show in Finder")

            // 主操作 (Start / Install) 占据顶部最显眼位置. 装机未完成走 Install,
            // 装完 / 非 macOS 走 Start.
            if needsInstall {
                Button(action: installAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text("Install")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(item.config.macOS?.ipsw == nil)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("跑 VZMacOSInstaller 装 macOS 到主盘. 装完此按钮变为 Start")
            } else {
                Button(action: startAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("Start")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    // MARK: resources

    private var resourcesSection: some View {
        TerminalSection("Resources") {
            HStack(spacing: HVMSpace.md) {
                Button { model.editConfigItem = item } label: {
                    statCard(label: "CPU", value: "\(item.config.cpuCount)", unit: "cores", tint: HVMColor.statCPU)
                }
                .buttonStyle(.plain)
                .help("点击编辑 CPU 核数")

                Button { model.editConfigItem = item } label: {
                    statCard(label: "Memory", value: "\(item.config.memoryMiB / 1024)", unit: "GB", tint: HVMColor.statMemory)
                }
                .buttonStyle(.plain)
                .help("点击编辑内存")

                statCard(label: "Disk", value: "\(item.config.disks.first?.sizeGiB ?? 0)", unit: "GB", tint: HVMColor.statDisk)
                statCard(label: "Network", value: networkMode(item.config), unit: nil, tint: HVMColor.statNetwork)
            }
        }
    }

    @ViewBuilder
    private func statCard(label: String, value: String, unit: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            Text(label)
                .font(HVMFont.label)
                .foregroundStyle(tint)
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

    // MARK: metadata

    private var metadataSection: some View {
        TerminalSection("General") {
            VStack(spacing: 0) {
                kvRow("ID",     item.config.id.uuidString.lowercased(), truncating: true, mono: true, first: true)
                kvRow("MAC",    item.config.networks.first?.macAddress ?? "—", mono: true)
                if item.guestOS == .macOS {
                    kvRow("IPSW",      item.config.macOS?.ipsw ?? "—", truncating: true, mono: true)
                    kvRow("Installed", item.config.macOS?.autoInstalled == true ? "Yes (auto)" : "No — run install")
                } else {
                    kvRow("ISO", item.config.installerISO ?? "—", truncating: true, mono: true)
                }
                kvRow("Boot",   bootModeLabel)
                kvRow("Bundle", item.bundleURL.path, truncating: true, mono: true, last: true)
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    // MARK: disks

    private var disksSection: some View {
        TerminalSection("Disks") {
            VStack(spacing: 0) {
                disksHeader
                disksRows
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    private var disksHeader: some View {
        HStack(spacing: HVMSpace.md) {
            Text("\(item.config.disks.count) attached")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()
            Button {
                model.diskAddItem = item
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add Disk")
                }
            }
            .buttonStyle(GhostButtonStyle())
            .help("加一块数据盘 (raw sparse)")
        }
        .padding(.horizontal, HVMSpace.md)
        .padding(.vertical, HVMSpace.sm)
    }

    private var disksRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(item.config.disks.enumerated()), id: \.offset) { _, disk in
                Rectangle().fill(HVMColor.border).frame(height: 1)
                diskRow(disk)
            }
        }
    }

    @ViewBuilder
    private func diskRow(_ disk: DiskSpec) -> some View {
        let id = diskID(for: disk)
        let absURL = item.bundleURL.appendingPathComponent(disk.path)
        let actualBytes = (try? DiskFactory.actualBytes(at: absURL)) ?? 0
        HStack(spacing: HVMSpace.md) {
            Circle()
                .fill(disk.role == .main ? HVMColor.accent : HVMColor.statNetwork)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HVMSpace.sm) {
                    Text(id)
                        .font(HVMFont.mono)
                        .foregroundStyle(HVMColor.textPrimary)
                    Text(disk.role == .main ? "main" : "data")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                }
                Text("\(disk.sizeGiB) GB · 实占 \(formatMB(actualBytes))")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            Spacer()
            Button("Resize") {
                model.diskResizeRequest = AppModel.DiskResizeRequest(
                    item: item, diskID: id, currentSizeGiB: disk.sizeGiB
                )
            }
            .buttonStyle(GhostButtonStyle())
            .help("扩容磁盘 (只能增大)")
            if disk.role == .data {
                Button("Delete") { deleteDataDisk(id: id) }
                    .buttonStyle(GhostButtonStyle(destructive: true))
                    .help("删除此数据盘")
            }
        }
        .padding(.horizontal, HVMSpace.md)
        .padding(.vertical, 9)
    }

    private func diskID(for disk: DiskSpec) -> String {
        if disk.role == .main { return "main" }
        let prefix = "\(BundleLayout.disksDirName)/data-"
        let suffix = ".img"
        guard disk.path.hasPrefix(prefix), disk.path.hasSuffix(suffix) else { return "?" }
        return String(disk.path.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private func formatMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    private func deleteDataDisk(id: String) {
        confirms.present(ConfirmDialogModel(
            title: "删除数据盘",
            message: "确定删除数据盘 \"\(id)\"? 此操作不可撤销。",
            confirmTitle: "删除",
            cancelTitle: "取消",
            destructive: true
        )) { confirmed in
            guard confirmed else { return }
            do {
                if BundleLock.isBusy(bundleURL: item.bundleURL) {
                    throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
                }
                var config = try BundleIO.load(from: item.bundleURL)
                let relPath = "\(BundleLayout.disksDirName)/data-\(id).img"
                guard let idx = config.disks.firstIndex(where: { $0.role == .data && $0.path == relPath }) else {
                    throw HVMError.config(.missingField(name: "data disk id=\(id) 未找到"))
                }
                let absURL = item.bundleURL.appendingPathComponent(config.disks[idx].path)
                try DiskFactory.delete(at: absURL)
                config.disks.remove(at: idx)
                try BundleIO.save(config: config, to: item.bundleURL)
                model.refreshList()
            } catch {
                errors.present(error)
            }
        }
    }

    // MARK: snapshots

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
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Snapshot")
                }
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
                Text("No snapshots yet")
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
                    Button("Restore") { restoreSnapshot(info.name) }
                        .buttonStyle(GhostButtonStyle())
                        .help("将磁盘和 config 还原到此快照")
                    Button("Delete") { deleteSnapshot(info.name) }
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

    private var bootModeLabel: String {
        if item.config.bootFromDiskOnly { return "From disk" }
        switch item.guestOS {
        case .linux, .windows: return "From ISO (installer mode)"
        case .macOS:           return "From IPSW (installer mode)"
        }
    }

    @ViewBuilder
    private func kvRow(_ key: String, _ value: String,
                       truncating: Bool = false,
                       mono: Bool = false,
                       first: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle().fill(HVMColor.border).frame(height: 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: HVMSpace.md) {
                Text(key)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .frame(width: 80, alignment: .leading)
                if truncating {
                    Text(value)
                        .font(mono ? HVMFont.monoSmall : HVMFont.caption)
                        .foregroundStyle(HVMColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(value)
                        .font(mono ? HVMFont.monoSmall : HVMFont.caption)
                        .foregroundStyle(HVMColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 9)
        }
    }

    // MARK: action row

    private var actionRow: some View {
        HStack(spacing: HVMSpace.md) {
            Spacer()
            // ISO 切换 (仅 Linux). 等价 hvm-cli iso select / eject
            if item.guestOS == .linux {
                Button(item.config.installerISO != nil ? "Change ISO" : "Select ISO") {
                    selectIsoAction()
                }
                .buttonStyle(GhostButtonStyle())
                .help("挂载 / 替换安装 ISO (会自动取消 bootFromDiskOnly)")

                if item.config.installerISO != nil {
                    Button("Eject ISO") { ejectIsoAction() }
                        .buttonStyle(GhostButtonStyle())
                        .help("弹出 ISO 并切到仅硬盘启动")
                }
            }

            if !needsInstall, item.config.installerISO != nil, !item.config.bootFromDiskOnly {
                Button(action: bootFromDiskAction) {
                    Text("Boot From Disk")
                }
                .buttonStyle(GhostButtonStyle())
                .help("装完 OS 后切到只从硬盘启动")
            }

            // 危险操作 (Delete) 放最右, 走 ConfirmDialog 弹窗确认避免误触.
            Button(role: .destructive) { deleteAction() } label: {
                Text("Delete")
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
            .help("将虚拟机 bundle 移到废纸篓")
        }
    }

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
        confirms.present(ConfirmDialogModel(
            title: "删除虚拟机",
            message: "将 \"\(item.displayName)\" 移到废纸篓? bundle 整体 (主盘 / 数据盘 / config / snapshots) 一并移除, 可从废纸篓恢复。",
            confirmTitle: "删除",
            cancelTitle: "取消",
            destructive: true
        )) { confirmed in
            guard confirmed else { return }
            do {
                var resultURL: NSURL?
                try FileManager.default.trashItem(at: item.bundleURL, resultingItemURL: &resultURL)
                model.refreshList()
            } catch {
                errors.present(error)
            }
        }
    }

    private func networkMode(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "—" }
        switch net.mode {
        case .nat:     return "NAT"
        case .bridged: return "Bridged"
        case .shared:  return "Shared"
        }
    }
}

// MARK: - 空状态 (未选中 VM)
// 干净的 welcome 屏: VM stack icon + 标题 + 描述 + CTA. 无 ASCII banner / 无 boot log.

struct DetailEmptyState: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: HVMSpace.lg) {
            Spacer(minLength: HVMSpace.xl)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(HVMColor.bgCard)
                    .frame(width: 88, height: 88)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(HVMColor.accent)
            }

            VStack(spacing: HVMSpace.sm) {
                Text(headlineText)
                    .font(HVMFont.title)
                    .foregroundStyle(HVMColor.textPrimary)
                Text(subText)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if model.list.isEmpty {
                Button(action: { model.showCreateWizard = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Create VM")
                    }
                }
                .buttonStyle(HeroCTAStyle())
                Text("Cmd+N")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }

            Spacer(minLength: HVMSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HVMColor.bgBase)
    }

    private var headlineText: String {
        model.list.isEmpty ? "Welcome to HVM" : "No VM selected"
    }

    private var subText: String {
        if model.list.isEmpty {
            return "Create your first virtual machine. Supports macOS, Linux (VZ / QEMU), and Windows arm64 (QEMU)."
        } else {
            return "Pick a VM from the list on the left to view details, manage disks and snapshots, or start it."
        }
    }
}

// MARK: - Remote Running 占位
// QEMU 后端 / hvm-cli 起的 VM: BundleLock 显示 running 但本 GUI 进程无 session.
// QEMU 后端的 cocoa 窗口由 QEMU 进程独立展示, HVM 主窗口的 detail 区不嵌入画面,
// 只给一个状态卡片 + Stop/Kill 控制 (model.stop / .kill 内部已对外部 host 进程走 IPC fallback).

struct RemoteRunningContentView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    var body: some View {
        VStack(spacing: HVMSpace.lg) {
            Spacer(minLength: HVMSpace.xl)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(HVMColor.bgCard)
                    .frame(width: 88, height: 88)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(HVMColor.statusRunning)
            }

            VStack(spacing: HVMSpace.sm) {
                HStack(spacing: HVMSpace.sm) {
                    GuestBadge(os: item.guestOS, size: 24)
                    Text(item.displayName)
                        .font(HVMFont.title)
                        .foregroundStyle(HVMColor.textPrimary)
                }
                StatusBadge(state: .running)
                Text(subText)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: HVMSpace.md) {
                Button("Stop") {
                    do { try model.stop(item.id) } catch { errors.present(error) }
                }
                .buttonStyle(GhostButtonStyle())
                .help("请求 guest 优雅关机 (走 IPC)")

                Button("Kill") {
                    Task { do { try await model.kill(item.id) } catch { errors.present(error) } }
                }
                .buttonStyle(GhostButtonStyle(destructive: true))
                .help("强制结束 host 进程 (走 IPC)")
            }

            Spacer(minLength: HVMSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HVMColor.bgBase)
    }

    private var subText: String {
        switch item.guestOS {
        case .windows, .linux:
            return "QEMU 后端的画面在独立的 QEMU 窗口中。如果窗口被遮挡, 在 Dock 找 qemu-system-aarch64 切回前台。"
        case .macOS:
            return "VM 由其他进程接管中 (本 GUI 不持有 session)。"
        }
    }
}
