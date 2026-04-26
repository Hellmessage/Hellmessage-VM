// IpswCatalogPicker.swift
// macOS IPSW 版本选择器 modal. 弹出时拉 Apple mesu catalog, 列所有 VZ 可用 build,
// 用户挑一行点 "Fetch" 就开始下载 (走 AppModel.startIpswFetch(entry:)).
//
// 数据源: IPSWFetcher.fetchCatalog(). 列只展示 osVersion / buildVersion / postingDate / cached 标记;
// minCPU/minMemoryMiB 在 catalog 里没有 (mesu plist 不带), 真正装机时由 RestoreImageHandle.load 拿.
//
// AppModel.ipswCatalogPicker != nil 时由 DialogOverlay 显示.

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
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Divider().background(HVMColor.border)
                content
                Divider().background(HVMColor.border)
                footer
            }
            .frame(width: 640, height: 520)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
        }
        .task { await loadCatalog() }
    }

    private var header: some View {
        HStack(spacing: HVMSpace.md) {
            Text("Choose macOS Version")
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("w", modifiers: [.command])
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
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
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(HVMSpace.xl)
        } else if let err = loadError {
            VStack(alignment: .leading, spacing: HVMSpace.md) {
                Text("拉取 catalog 失败")
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.statusError)
                Text(err)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)
                Text("// 可能 Apple catalog 端点格式变了, 或网络受限. 可改用 hvm-cli ipsw fetch --url <url> 自带 IPSW URL")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HVMSpace.xl)
        } else if entries.isEmpty {
            VStack(spacing: HVMSpace.md) {
                Text("(catalog 为空)")
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(HVMSpace.xl)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.buildVersion) { idx, entry in
                        if idx > 0 { Rectangle().fill(HVMColor.border).frame(height: 1) }
                        row(for: entry)
                    }
                }
            }
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
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? HVMColor.accent : HVMColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HVMSpace.sm) {
                        Text("macOS \(entry.osVersion)")
                            .font(HVMFont.bodyBold)
                            .foregroundStyle(HVMColor.textPrimary)
                        Text(entry.buildVersion)
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textSecondary)
                        if cached {
                            Text("CACHED")
                                .font(HVMFont.label)
                                .tracking(1.2)
                                .foregroundStyle(HVMColor.statusRunning)
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
            .padding(.horizontal, HVMSpace.lg)
            .padding(.vertical, 10)
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
                Text("// 选一个版本, 点 Fetch 开始下载")
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
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
    }

    private func loadCatalog() async {
        loading = true
        loadError = nil
        do {
            let list = try await IPSWFetcher.fetchCatalog()
            entries = list
            loading = false
            // 默认选最新条目 (catalog 已按 PostingDate 倒序)
            selected = list.first
        } catch let e as HVMError {
            // userFacing.message 是泛泛的 "IPSW 下载失败", 真正的原因在 details["reason"] 里
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
        // 先关 picker, 再触发 onSelect — 避免 picker 还在屏幕上时 IpswFetchDialog 也 layer 过来视觉混乱
        let cb = onSelect
        close()
        cb(entry)
    }

    private func close() {
        model.ipswCatalogPicker = nil
    }
}
