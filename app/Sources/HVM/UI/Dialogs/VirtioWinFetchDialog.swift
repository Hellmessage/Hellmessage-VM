// VirtioWinFetchDialog.swift
// virtio-win.iso 下载进度模态. AppModel.virtioWinFetchState 非 nil 时由 DialogOverlay 显示.
//
// 对标 IpswFetchDialog: 同样无 Cancel 按钮 (中途取消 .partial 留 cache 目录, 下次重试),
// 失败走 errors.present 标准弹窗.

import SwiftUI

struct VirtioWinFetchDialog: View {
    let state: AppModel.VirtioWinFetchState

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Divider().background(HVMColor.border)
                body_
            }
            .frame(width: 480)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
        }
    }

    private var header: some View {
        HStack {
            Text("Fetching virtio-win drivers")
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
            Spacer()
            // 故意无 X: 中途取消语义不清; 失败走 errors.present
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            HStack {
                Text("virtio-win.iso")
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textPrimary)
                Spacer()
                Text("WIN ARM64")
                    .font(HVMFont.label)
                    .tracking(1.5)
                    .foregroundStyle(HVMColor.textTertiary)
            }

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                progressBar
                Text(progressDetail)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text("// Fedora 官方 virtio 驱动 ISO (~700 MiB). Win11 装机看不到磁盘时, 从这盘加载 viostor.sys 即可识别.")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HVMSpace.lg)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let f = state.fraction {
            // determinate
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: HVMRadius.sm)
                        .fill(HVMColor.bgBase)
                    RoundedRectangle(cornerRadius: HVMRadius.sm)
                        .fill(HVMColor.accent)
                        .frame(width: max(0, geo.size.width * CGFloat(f)))
                }
            }
            .frame(height: 6)
        } else {
            // indeterminate (服务端没给 Content-Length 或起步阶段)
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .fill(HVMColor.bgBase)
                .frame(height: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMRadius.sm)
                        .fill(HVMColor.accent.opacity(0.5))
                        .frame(width: 60)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: 0)   // 简化版, 不做条纹滚动动画
                )
        }
    }

    private var progressDetail: String {
        let received = formatBytes(state.receivedBytes)
        if let t = state.totalBytes {
            let pct = Int(((state.fraction ?? 0) * 100).rounded())
            return "\(received) / \(formatBytes(t))  ·  \(pct)%"
        } else {
            return "\(received)  ·  连接中…"
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        let gb = 1024.0 * 1024 * 1024
        let mb = 1024.0 * 1024
        let v = Double(n)
        if v >= gb { return String(format: "%.2f GiB", v / gb) }
        if v >= mb { return String(format: "%.0f MiB", v / mb) }
        return "\(n) B"
    }
}
