// IpswFetchDialog.swift
// IPSW 下载进度模态. 套 HVMModal, closeAction = nil (下载不可取消, 失败走 errors).
// 视觉:
//   - 已知 total → DeterminateBar
//   - 未知 total (resolving / 起步) → IndeterminateBar 渐变光柱

import SwiftUI
import HVMUtils

struct IpswFetchDialog: View {
    let state: AppModel.IpswFetchState

    var body: some View {
        HVMModal(
            title: "Fetching IPSW",
            icon: .info,
            width: 480,
            closeAction: nil
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                HStack(spacing: HVMSpace.sm) {
                    Text(state.info)
                        .font(HVMFont.bodyBold)
                        .foregroundStyle(HVMColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(phaseLabel)
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

                Text("IPSW 通常 10-15 GiB. 中途断网 / 关闭 App 都安全, 下次再点 fetch 会从断点续传.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case .resolving:     return "Resolving"
        case .downloading:   return "Downloading"
        case .alreadyCached: return "Cached"
        case .completed:     return "Completed"
        }
    }

    private var progressDetail: String {
        switch state.phase {
        case .resolving:
            return "querying VZMacOSRestoreImage.fetchLatestSupported…"
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
        case .downloading:
            if let total = state.totalBytes, total > 0 {
                DeterminateBar(fraction: CGFloat(Double(state.receivedBytes) / Double(total)))
            } else {
                IndeterminateBar()
            }
        case .resolving:
            IndeterminateBar()
        }
    }
}

// MARK: - 进度条组件

struct DeterminateBar: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.bgBase)
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.accent)
                    .frame(width: max(2, geo.size.width * max(0, min(1, fraction))))
                    .animation(.easeOut(duration: 0.15), value: fraction)
            }
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.sm))
        }
        .frame(height: 6)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }
}

struct IndeterminateBar: View {
    @State private var offset: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.bgBase)
                LinearGradient(
                    colors: [
                        HVMColor.accent.opacity(0.0),
                        HVMColor.accent.opacity(0.85),
                        HVMColor.accent.opacity(0.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.35)
                .offset(x: geo.size.width * offset)
            }
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.sm))
        }
        .frame(height: 6)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                offset = 1.0
            }
        }
    }
}
