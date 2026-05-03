// VirtioWinFetchDialog.swift
// virtio-win.iso 下载进度模态. 套 HVMModal, closeAction = nil.
// 复用 IpswFetchDialog 里的 DeterminateBar / IndeterminateBar.

import SwiftUI
import HVMUtils

struct VirtioWinFetchDialog: View {
    let state: AppModel.VirtioWinFetchState

    var body: some View {
        HVMModal(
            title: "Fetching virtio-win drivers",
            icon: .info,
            width: 480,
            closeAction: nil
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                HStack {
                    Text("virtio-win.iso")
                        .font(HVMFont.bodyBold)
                        .foregroundStyle(HVMColor.textPrimary)
                    Spacer()
                    Text("Win arm64")
                        .font(HVMFont.label)
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

                Text("Fedora 官方 virtio 驱动 ISO (~700 MiB). Win11 装机看不到磁盘时, 从这盘加载 viostor.sys 即可识别.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let f = state.fraction {
            DeterminateBar(fraction: CGFloat(f))
        } else {
            IndeterminateBar()
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
        Format.bytes(n)
    }
}
