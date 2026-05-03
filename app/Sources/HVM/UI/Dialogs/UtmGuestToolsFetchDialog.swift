// UtmGuestToolsFetchDialog.swift
// utm-guest-tools.iso 下载进度模态. 套 HVMModal, closeAction = nil.
// 复用 IpswFetchDialog 里的 DeterminateBar / IndeterminateBar.

import SwiftUI
import HVMUtils

struct UtmGuestToolsFetchDialog: View {
    let state: AppModel.UtmGuestToolsFetchState

    var body: some View {
        HVMModal(
            title: "Fetching UTM Guest Tools",
            icon: .info,
            width: 480,
            closeAction: nil
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                HStack {
                    Text("utm-guest-tools.iso")
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

                Text("UTM 官方 Guest Tools ISO (~120 MiB). 含 ARM64 native vdagent + viogpudo + qemu-ga, Win 装机后自动 NSIS 静默装, 让拖窗口动态 resize / qemu-guest-agent 都生效.")
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
