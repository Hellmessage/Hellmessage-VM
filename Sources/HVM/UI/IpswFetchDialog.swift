// IpswFetchDialog.swift
// IPSW 下载进度模态. AppModel.ipswFetchState 非 nil 时由 DialogOverlay 显示.
//
// 与 InstallDialog 一样不提供 Cancel: URLSession download task 中断会留下临时文件,
// 且 IPSW 通常 10-15 GiB, 中断后续重下又得从头开始. 用户必须等. 失败走 errors.present.
//
// 视觉与 InstallDialog 保持一致 (同样 480 宽 + 黑色 card + 进度条 + 关闭无 X).

import SwiftUI

struct IpswFetchDialog: View {
    let state: AppModel.IpswFetchState

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
        HStack(spacing: HVMSpace.md) {
            Text("Fetching IPSW")
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
            Spacer()
            // 故意无 X: 下载中途取消会让用户白等. 失败走 errors.present.
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
    }

    private var body_: some View {
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
                    .tracking(1.5)
                    .foregroundStyle(HVMColor.textTertiary)
            }

            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                progressBar
                Text(percentLabel)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
                    .monospacedDigit()
            }

            Text("// IPSW 通常 10-15 GiB, 取决于你的网速可能持续数分钟到一小时. 下载到 ~/Library/Application Support/HVM/cache/ipsw/")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(HVMSpace.lg)
    }

    private var phaseLabel: String {
        switch state.phase {
        case .resolving:     return "RESOLVING"
        case .downloading:   return "DOWNLOADING"
        case .alreadyCached: return "CACHED"
        case .completed:     return "COMPLETED"
        }
    }

    private var percentLabel: String {
        switch state.phase {
        case .resolving:
            return "querying VZMacOSRestoreImage.fetchLatestSupported…"
        case .downloading:
            let recv = Self.formatBytes(state.receivedBytes)
            if let total = state.totalBytes, total > 0 {
                let pct = Double(state.receivedBytes) / Double(total) * 100
                return "\(String(format: "%.1f%%", pct))   \(recv) / \(Self.formatBytes(total))"
            }
            // total 未知 (resume 起步阶段, 等服务器 Content-Range 才知道完整大小)
            return "\(recv) / ?  (resuming…)"
        case .alreadyCached:
            return "cache hit, skip download (\(Self.formatBytes(state.receivedBytes)))"
        case .completed:
            return "done (\(Self.formatBytes(state.receivedBytes)))"
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.bgBase)
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.accent)
                    .frame(width: max(2, geo.size.width * fillFraction))
                    .animation(.easeOut(duration: 0.15), value: fillFraction)
            }
        }
        .frame(height: 6)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    private var fillFraction: CGFloat {
        switch state.phase {
        case .resolving:     return 0.02
        case .downloading:
            guard let t = state.totalBytes, t > 0 else { return 0.05 }
            return CGFloat(Double(state.receivedBytes) / Double(t))
        case .alreadyCached: return 1.0
        case .completed:     return 1.0
        }
    }

    private static func formatBytes(_ n: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let v = Double(n)
        if v >= gb { return String(format: "%.2f GiB", v / gb) }
        if v >= mb { return String(format: "%.1f MiB", v / mb) }
        if v >= kb { return String(format: "%.1f KiB", v / kb) }
        return "\(n) B"
    }
}
