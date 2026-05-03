// OSImagePickerDialog.swift
// Linux 发行版 / Windows custom URL 镜像选择器. 套 HVMModal.
// - guestOS == .linux: 列出 OSImageCatalog 内置 6 个发行版 + custom URL 区
// - guestOS == .windows: 隐藏 catalog (Win11 无官方直链, Win10 已无来源), 只暴露 custom URL
//                        + Win10 不可用提示文案
// 用户选完点 Download → 委托 AppModel.startOSImageFetch / startOSImageCustomFetch.

import SwiftUI
import HVMBundle
import HVMCore
import HVMInstall
import HVMUtils

struct OSImagePickerDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let request: AppModel.OSImagePickerRequest

    @State private var selectedEntry: OSImageEntry? = nil
    @State private var customURLString: String = ""

    private var isLinux: Bool { request.guestOS == .linux }
    private var entries: [OSImageEntry] {
        isLinux ? OSImageCatalog.entries.filter { $0.guestOS == "linux" } : []
    }

    private var customURL: URL? {
        let trimmed = customURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let u = URL(string: trimmed), let scheme = u.scheme,
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return u
    }

    var body: some View {
        HVMModal(
            title: isLinux ? "Download Linux ISO" : "Download Windows ISO",
            icon: .info,
            width: 680,
            height: isLinux ? 580 : 360,
            closeAction: { close() }
        ) {
            content
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            if !isLinux {
                windowsBanner
            }
            if isLinux && !entries.isEmpty {
                LabelText("Distributions (arm64)")
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            if idx > 0 { Rectangle().fill(HVMColor.border).frame(height: 1) }
                            row(for: entry)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
            }

            customURLSection
        }
    }

    @ViewBuilder
    private var windowsBanner: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            Text("Windows 11 ARM64")
                .font(HVMFont.bodyBold)
                .foregroundStyle(HVMColor.textPrimary)
            Text("微软官方未提供 Win11 ARM64 直链 ISO. 获取来源:")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textSecondary)
            Text("• Windows Insider Program (需注册微软账号)")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Text("• 社区工具 UUP Dump (从微软服务器拉 chunks 本地组装 ISO)")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Text("拿到 ISO 后填入下方 URL 直接下载, 或用 Browse 选本地文件.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Divider().padding(.vertical, HVMSpace.xs)
            Text("Windows 10 ARM64")
                .font(HVMFont.bodyBold)
                .foregroundStyle(HVMColor.textPrimary)
            Text("微软已停止官方分发 Windows 10 ARM64 ISO. 推荐使用 Win11.")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.statusError)
        }
        .padding(HVMSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
        .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
    }

    @ViewBuilder
    private func row(for entry: OSImageEntry) -> some View {
        let isSelected = selectedEntry?.id == entry.id
        let cached = OSImageFetcher.isCached(entry: entry)
        Button {
            selectedEntry = entry
        } label: {
            HStack(spacing: HVMSpace.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? HVMColor.accent : HVMColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HVMSpace.sm) {
                        Text(entry.displayName)
                            .font(HVMFont.bodyBold)
                            .foregroundStyle(HVMColor.textPrimary)
                        Text(entry.version)
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textSecondary)
                        if cached {
                            Text("CACHED")
                                .font(HVMFont.label)
                                .foregroundStyle(HVMColor.statusRunning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(HVMColor.statusRunning.opacity(0.15)))
                        }
                        Spacer(minLength: 0)
                        if entry.approximateSize > 0 {
                            Text("~\(Format.bytes(entry.approximateSize))")
                                .font(HVMFont.monoSmall)
                                .foregroundStyle(HVMColor.textTertiary)
                        }
                    }
                    if let hint = entry.hint {
                        Text(hint)
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? HVMColor.bgSelected : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customURLSection: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText(isLinux ? "Or download from URL" : "ISO download URL")
            HVMTextField(
                "https://example.com/path/to.iso",
                text: $customURLString,
                action: nil
            )
            Text("不在 SHA256 catalog 内, 跳过校验. 适用于 Win11 ARM ISO / 自管发行版 / mirror 直链.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: HVMSpace.md) {
            statusLine
            Spacer()
            Button("Cancel") { close() }
                .buttonStyle(GhostButtonStyle())
            Button("Download") { confirm() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedEntry == nil && customURL == nil)
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let s = selectedEntry {
            Text("已选: \(s.displayName)")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let u = customURL {
            Text("自定义: \(u.lastPathComponent)")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(isLinux ? "选一个发行版或填 Custom URL" : "填 ISO URL")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        }
    }

    private func confirm() {
        let cb = request.onSelect
        // 优先 catalog entry, 其次 custom URL (避免两边同时填时选错)
        if let entry = selectedEntry {
            close()
            model.startOSImageFetch(entry: entry, errors: errors) { localURL in
                cb(localURL)
            }
            return
        }
        if let url = customURL {
            close()
            model.startOSImageCustomFetch(url: url, errors: errors) { localURL in
                cb(localURL)
            }
            return
        }
    }

    private func close() {
        model.osImagePickerRequest = nil
    }
}
