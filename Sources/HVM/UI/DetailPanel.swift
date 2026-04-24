// DetailPanel.swift
// Hacker terminal 风: 无彩色渐变, 全黑 + 青绿 accent + mono kv sections

import AppKit
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplay

struct DetailPanel: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        if let item = model.selectedItem {
            content(for: item)
                .background(HVMColor.bgBase)
        } else {
            emptyState
                .background(HVMColor.bgBase)
        }
    }

    private var emptyState: some View {
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
    }

    @ViewBuilder
    private func content(for item: AppModel.VMListItem) -> some View {
        if let session = model.sessions[item.id] {
            runningContent(session: session, item: item)
        } else {
            stoppedContent(item: item)
        }
    }

    // MARK: - running

    @ViewBuilder
    private func runningContent(session: VMSession, item: AppModel.VMListItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: HVMSpace.md) {
                GuestBadge(os: item.guestOS, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(HVMFont.heading)
                        .foregroundStyle(HVMColor.textPrimary)
                    statusRow(state: session.state)
                }
                Spacer()
                if session.displayMode == .embedded {
                    Button { model.popOutStandalone(item.id) } label: {
                        Text("POP OUT")
                    }
                    .buttonStyle(GhostButtonStyle())
                } else if session.displayMode == .standalone {
                    Button { model.embedInMain(item.id) } label: {
                        Text("EMBED")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, HVMSpace.xl)
            .padding(.vertical, HVMSpace.md)

            Divider().background(HVMColor.border)

            ZStack {
                Color.black
                if session.displayMode == .embedded {
                    EmbeddedVMContent(attachment: session.attachment)
                } else {
                    VStack(spacing: HVMSpace.md) {
                        Text("[display in standalone window]")
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textTertiary)
                        Button("Embed here") { model.embedInMain(item.id) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }

            Divider().background(HVMColor.border)

            HStack(spacing: HVMSpace.md) {
                Text("\(item.config.cpuCount)cpu · \(item.config.memoryMiB / 1024)gb · \(networkModeString(item.config).lowercased())")
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
        }
    }

    // MARK: - stopped

    @ViewBuilder
    private func stoppedContent(item: AppModel.VMListItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HVMSpace.xl) {
                titleBlock(item: item)
                resourcesSection(item: item)
                metadataSection(item: item)
                actionRow(item: item)
            }
            .padding(HVMSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 标题块

    @ViewBuilder
    private func titleBlock(item: AppModel.VMListItem) -> some View {
        HStack(alignment: .center, spacing: HVMSpace.lg) {
            GuestBadge(os: item.guestOS, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .font(HVMFont.hero)
                    .foregroundStyle(HVMColor.textPrimary)
                HStack(spacing: HVMSpace.sm) {
                    statusRow(state: .stopped)
                    Text("·")
                        .foregroundStyle(HVMColor.textTertiary)
                    Text(GuestVisual.style(for: item.guestOS).label)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)
                }
            }
            Spacer()
            Menu {
                Button(role: .destructive) { deleteAction(item) } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.bundleURL]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            } label: {
                Text("···")
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textSecondary)
                    .frame(width: 32, height: 28)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Resources section

    @ViewBuilder
    private func resourcesSection(item: AppModel.VMListItem) -> some View {
        TerminalSection("Resources") {
            HStack(spacing: HVMSpace.md) {
                statCard(label: "cpu",
                         value: "\(item.config.cpuCount)", unit: "cores",
                         tint: HVMColor.statCPU)
                statCard(label: "memory",
                         value: "\(item.config.memoryMiB / 1024)", unit: "gb",
                         tint: HVMColor.statMemory)
                statCard(label: "disk",
                         value: "\(item.config.disks.first?.sizeGiB ?? 0)", unit: "gb",
                         tint: HVMColor.statDisk)
                statCard(label: "network",
                         value: networkModeString(item.config).lowercased(), unit: nil,
                         tint: HVMColor.statNetwork)
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
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .fill(HVMColor.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    // MARK: - Metadata section (kv list)

    @ViewBuilder
    private func metadataSection(item: AppModel.VMListItem) -> some View {
        TerminalSection("Metadata") {
            VStack(spacing: 0) {
                kvRow("id",     item.config.id.uuidString.lowercased(), truncating: true, first: true)
                kvRow("mac",    item.config.networks.first?.macAddress ?? "—")
                kvRow("iso",    item.config.installerISO ?? "—", truncating: true)
                kvRow("boot",   item.config.bootFromDiskOnly ? "from disk" : "from iso (installer mode)")
                kvRow("bundle", item.bundleURL.path, truncating: true, last: true)
            }
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(HVMColor.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func kvRow(_ key: String, _ value: String,
                       truncating: Bool = false,
                       first: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle()
                    .fill(HVMColor.border)
                    .frame(height: 1)
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

    // MARK: - action row

    @ViewBuilder
    private func actionRow(item: AppModel.VMListItem) -> some View {
        HStack(spacing: HVMSpace.md) {
            Button(action: { startAction(item) }) {
                HStack(spacing: 6) {
                    Text("▶").font(.system(size: 10))
                    Text("START")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    // MARK: - status row

    @ViewBuilder
    private func statusRow(state: RunState) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .stopped: return ("stopped", HVMColor.statusStopped)
            case .starting: return ("starting", HVMColor.statusPaused)
            case .running: return ("running", HVMColor.statusRunning)
            case .paused: return ("paused", HVMColor.statusPaused)
            case .stopping: return ("stopping", HVMColor.statusPaused)
            case .error: return ("error", HVMColor.statusError)
            }
        }()
        HStack(spacing: 5) {
            if case .running = state {
                PulseDot(color: color, size: 5)
            } else {
                Text("●")
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(HVMFont.caption)
                .foregroundStyle(color)
        }
    }

    // MARK: - actions

    private func startAction(_ item: AppModel.VMListItem) {
        Task {
            do { try await model.start(item) } catch { errors.present(error) }
        }
    }

    private func deleteAction(_ item: AppModel.VMListItem) {
        do {
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: item.bundleURL, resultingItemURL: &resultURL)
            model.refreshList()
        } catch {
            errors.present(error)
        }
    }

    private func networkModeString(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "—" }
        switch net.mode {
        case .nat: return "NAT"
        case .bridged: return "Bridged"
        }
    }
}
