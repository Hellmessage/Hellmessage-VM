// HVM/UI/Shell/MenuPopoverView.swift
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
                .font(HVMFont.monoBody)
                .foregroundStyle(HVMColor.statusRunning)
            Text("//\(rows.count) running")
                .font(HVMFont.monoSmall)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, HVMSpace.popoverH14)
        .padding(.vertical, HVMSpace.buttonPadV10)
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            VStack(spacing: HVMSpace.sm) {
                Image(systemName: "shippingbox")
                    .font(HVMFont.bigRegular)
                    .foregroundStyle(.secondary)
                Text("No running VMs")
                    .font(HVMFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HVMSpace.popoverV28)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    VMPopoverRow(row: row)
                    if row.id != rows.last?.id {
                        // 70 = thumbnail (48) + spacing (12) + 一些缩进, 跟 thumbnail 右沿对齐;
                        // 是几何对齐而非 token 化间距, 不走 HVMSpace.
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .padding(.vertical, HVMSpace.xs)
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
            VStack(alignment: .leading, spacing: HVMSpace.v2) {
                Text(row.name)
                    .font(HVMFont.bodyMedium)
                    .lineLimit(1)
                Text(row.ip ?? "—")
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HVMSpace.xs)
            Circle()
                .fill(HVMColor.statusRunning)
                .frame(width: 7, height: 7)
                .shadow(color: HVMColor.statusRunning.opacity(0.6), radius: 3)
        }
        .padding(.horizontal, HVMSpace.popoverH14)
        .padding(.vertical, HVMSpace.sm)
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
                        .font(HVMFont.headingRegular)
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
                .font(HVMFont.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(hovering ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
