// OSImageFetchDialog.swift
// Linux ISO / 自定义 URL 下载进度模态. 套 HVMModal, closeAction = nil
// (装机不可中断, 失败走 errors).
//
// 视觉跟 IpswFetchDialog 对齐: phase 标签 + 进度条 + 详情行 (字节/速率/ETA).
// verifying 阶段单独显示 (大文件 SHA256 校验需要几秒到十几秒).

import SwiftUI
import HVMUtils

struct OSImageFetchDialog: View {
    let state: AppModel.OSImageFetchUIState

    var body: some View {
        HVMModal(
            title: "Fetching ISO",
            icon: .info,
            width: 640,
            closeAction: nil
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.md) {
                Text(state.info)
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: HVMSpace.sm) {
                    Text(phaseLabel)
                        .font(HVMFont.caption)
                        .foregroundStyle(HVMColor.textSecondary)
                    Text(progressDetail)
                        .font(HVMFont.monoSmall)
                        .foregroundStyle(HVMColor.textPrimary)
                        .monospacedDigit()
                }

                progressBar

                Text("Linux ISO 通常 600 MB - 3 GB. 中途断网 / 关闭 App 都安全, 下次再点 Download 会从断点续传.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case .downloading:   return "Downloading"
        case .verifying:     return "Verifying SHA256"
        case .alreadyCached: return "Cached"
        case .completed:     return "Completed"
        }
    }

    private var progressDetail: String {
        switch state.phase {
        case .downloading:
            let recv = Format.bytes(state.receivedBytes)
            var parts: [String] = []
            if let total = state.totalBytes, total > 0 {
                let pct = Double(state.receivedBytes) / Double(total) * 100
                parts.append("\(String(format: "%.1f%%", pct))   \(recv) / \(Format.bytes(total))")
            } else {
                parts.append("\(recv) / ?")
            }
            if let bps = state.bytesPerSecond {
                parts.append(Format.rate(bps))
            }
            if let eta = state.etaSeconds {
                parts.append("ETA \(Format.eta(eta))")
            }
            return parts.joined(separator: "  ·  ")
        case .verifying:
            return "computing SHA256 of \(Format.bytes(state.receivedBytes))…"
        case .alreadyCached:
            return "cache hit, skip download (\(Format.bytes(state.receivedBytes)))"
        case .completed:
            return "done (\(Format.bytes(state.receivedBytes)))"
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch state.phase {
        case .completed, .alreadyCached:
            DeterminateBar(fraction: 1.0)
        case .verifying:
            IndeterminateBar()
        case .downloading:
            if let total = state.totalBytes, total > 0 {
                DeterminateBar(fraction: CGFloat(Double(state.receivedBytes) / Double(total)))
            } else {
                IndeterminateBar()
            }
        }
    }
}
