// HVM/UI/MenuPopoverView.swift
// status item 弹出的 NSPopover 内容 (SwiftUI).
// 视觉风格: 深色 + monospace accent, 跟主窗口一致.
//
// 数据流: 弹出时由 HVMApp 一次性 snapshot model.sessions / IP / 缩略图, 注入 rows.
// 不持有 AppModel 引用, 不监听 (popover 是短开关, 关了重弹时再 snapshot).

import AppKit
import SwiftUI

/// 一行 VM 的数据快照
struct VMPopoverRowData: Identifiable {
    let id: UUID
    let name: String
    let ip: String?
    let thumbnail: NSImage?
    let onTap: () -> Void
}

struct MenuPopoverView: View {
    let rows: [VMPopoverRowData]
    let onShowMain: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320)
        .background(Color.black.opacity(0.001))  // 让 popover material 透出来
    }

    private var header: some View {
        HStack {
            Text("HVM")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green)
            Text("//\(rows.count) running")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("No running VMs")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    VMPopoverRow(row: row)
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            FooterButton(title: "显示主窗口", action: onShowMain)
            Divider().frame(height: 28)
            FooterButton(title: "退出 HVM", action: onQuit)
        }
        .frame(height: 36)
    }
}

private struct VMPopoverRow: View {
    let row: VMPopoverRowData
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(row.ip ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .shadow(color: .green.opacity(0.6), radius: 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(hovering ? Color.white.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture { row.onTap() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let img = row.thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 48, height: 32)
                .overlay(
                    Image(systemName: "shippingbox")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                )
        }
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(hovering ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
