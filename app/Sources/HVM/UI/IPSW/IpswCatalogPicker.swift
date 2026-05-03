// IpswCatalogPicker.swift
// macOS IPSW 版本选择器. 套 HVMModal, 内部一列可选 entries + Fetch 按钮.

import SwiftUI
import HVMCore
import HVMInstall

struct IpswCatalogPicker: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let onSelect: @MainActor (IPSWCatalogEntry) -> Void

    @State private var entries: [IPSWCatalogEntry] = []
    @State private var loading: Bool = true
    @State private var loadError: String? = nil
    @State private var selected: IPSWCatalogEntry? = nil

    var body: some View {
        HVMModal(
            title: "Choose macOS Version",
            icon: .info,
            width: 640,
            height: 520,
            closeAction: { close() }
        ) {
            content
        } footer: {
            footer
        }
        .task { await loadCatalog() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: HVMSpace.md) {
                ProgressView()
                Text("正在从 Apple catalog 拉版本列表…")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                Text("(\(IPSWFetcher.catalogURL.host ?? "mesu.apple.com"))")
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(alignment: .leading, spacing: HVMSpace.md) {
                Text("拉取 catalog 失败")
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.statusError)
                Text(err)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)
                Text("可能 Apple catalog 端点格式变了, 或网络受限. 可改用 hvm-cli ipsw fetch --url <url> 自带 IPSW URL")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if entries.isEmpty {
            VStack(spacing: HVMSpace.md) {
                Text("(catalog 为空)")
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.buildVersion) { idx, entry in
                        if idx > 0 { Rectangle().fill(HVMColor.border).frame(height: 1) }
                        row(for: entry)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func row(for entry: IPSWCatalogEntry) -> some View {
        let isSelected = selected?.buildVersion == entry.buildVersion
        let cached = IPSWFetcher.isCached(buildVersion: entry.buildVersion)
        Button {
            selected = entry
        } label: {
            HStack(spacing: HVMSpace.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(HVMFont.body)
                    .foregroundStyle(isSelected ? HVMColor.accent : HVMColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HVMSpace.sm) {
                        Text("macOS \(entry.osVersion)")
                            .font(HVMFont.bodyBold)
                            .foregroundStyle(HVMColor.textPrimary)
                        Text(entry.buildVersion)
                            .font(HVMFont.monoSmall)
                            .foregroundStyle(HVMColor.textSecondary)
                        if cached {
                            Text("CACHED")
                                .font(HVMFont.label)
                                .foregroundStyle(HVMColor.statusRunning)
                                .padding(.horizontal, HVMSpace.buttonPadV6)
                                .padding(.vertical, HVMSpace.v2)
                                .background(
                                    Capsule().fill(HVMColor.statusRunning.opacity(0.15))
                                )
                        }
                    }
                    Text(metadataLine(for: entry))
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, HVMSpace.buttonPadV10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? HVMColor.bgSelected : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func metadataLine(for entry: IPSWCatalogEntry) -> String {
        var parts: [String] = []
        if let pd = entry.postingDate {
            parts.append("posted \(Self.dateFmt.string(from: pd))")
        }
        parts.append(entry.url.absoluteString)
        return parts.joined(separator: "  ·  ")
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var footer: some View {
        HStack(spacing: HVMSpace.md) {
            if let s = selected {
                Text("已选: macOS \(s.osVersion) (\(s.buildVersion))")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !loading && loadError == nil && !entries.isEmpty {
                Text("选一个版本, 点 Fetch 开始下载")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            Spacer()
            Button("Cancel") { close() }
                .buttonStyle(GhostButtonStyle())
            Button("Fetch") { confirm() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == nil)
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private func loadCatalog() async {
        loading = true
        loadError = nil
        do {
            let list = try await IPSWFetcher.fetchCatalog()
            entries = list
            loading = false
            selected = list.first
        } catch let e as HVMError {
            let uf = e.userFacing
            var msg = uf.message
            if let reason = uf.details["reason"], !reason.isEmpty {
                msg += "\n\n原因: \(reason)"
            }
            if let hint = uf.hint {
                msg += "\n\n建议: \(hint)"
            }
            loadError = msg
            loading = false
        } catch {
            loadError = "\(error)"
            loading = false
        }
    }

    private func confirm() {
        guard let entry = selected else { return }
        let cb = onSelect
        close()
        cb(entry)
    }

    private func close() {
        model.ipswCatalogPicker = nil
    }
}
