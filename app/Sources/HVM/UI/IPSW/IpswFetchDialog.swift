// IpswFetchDialog.swift
// IPSW 下载进度模态. AppModel.ipswFetchState 非 nil 时由 DialogOverlay 显示.
//
// 不提供 Cancel: URLSession download task 中断会留下临时文件 (虽然有断点续传, 但
// 中途取消 UI 上没合理语义), 用户想停就 kill 进程或关 App, .partial 留在 cache,
// 下次再 fetch 自动续传. 失败由 errors.present 接管.
//
// 视觉: 480 宽黑卡片 + 阶段标签 + 进度条 + 字节/速率/ETA 文案.
// 进度条:
//   - 已知 total → 普通 determinate (受 fraction 推进)
//   - 未知 total (resolving / 续传起步) → IndeterminateBar 条纹动画

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
            // 故意无 X: 下载中途没合理取消语义. 失败走 errors.present.
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
                Text(progressDetail)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text("// IPSW 通常 10-15 GiB. 中途断网 / 关闭 App 都安全, 下次再点 fetch 会从断点续传.")
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

    /// 第二行: "12.31 GiB / 13.69 GiB · 12.4 MiB/s · ETA 6 min"
    private var progressDetail: String {
        switch state.phase {
        case .resolving:
            return "querying VZMacOSRestoreImage.fetchLatestSupported…"
        case .downloading:
            let recv = Self.formatBytes(state.receivedBytes)
            var parts: [String] = []
            if let total = state.totalBytes, total > 0 {
                let pct = Double(state.receivedBytes) / Double(total) * 100
                parts.append("\(String(format: "%.1f%%", pct))   \(recv) / \(Self.formatBytes(total))")
            } else {
                parts.append("\(recv) / ?")
            }
            if let bps = state.bytesPerSecond {
                parts.append(Self.formatRate(bps))
            }
            if let eta = state.etaSeconds {
                parts.append("ETA \(Self.formatETA(eta))")
            }
            return parts.joined(separator: "  ·  ")
        case .alreadyCached:
            return "cache hit, skip download (\(Self.formatBytes(state.receivedBytes)))"
        case .completed:
            return "done (\(Self.formatBytes(state.receivedBytes)))"
        }
    }

    // MARK: - 进度条 / indeterminate

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

    // MARK: - 格式化

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

    private static func formatRate(_ bps: Double) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        if bps >= gb { return String(format: "%.2f GiB/s", bps / gb) }
        if bps >= mb { return String(format: "%.1f MiB/s", bps / mb) }
        if bps >= kb { return String(format: "%.1f KiB/s", bps / kb) }
        return String(format: "%.0f B/s", bps)
    }

    private static func formatETA(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "--" }
        let s = Int(seconds)
        if s >= 3600 {
            return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
        }
        if s >= 60 {
            return "\(s / 60) min"
        }
        return "\(s) s"
    }
}

// MARK: - 进度条组件

private struct DeterminateBar: View {
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

/// 进度未知时用的 indeterminate 条纹动画 (替代 SwiftUI ProgressView indeterminate 的丑样式).
/// 一道渐变光柱左→右循环, 与 HVMColor.accent 同色调.
///
/// 注意: SwiftUI 的 `.offset(x:)` 不裁剪到父 frame, 必须在 GeometryReader 内层套
/// `.clipShape(...)` 否则动画光柱会沿 x 轴溢出.
private struct IndeterminateBar: View {
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
            // 必须在父容器裁: .offset 不影响 frame, 不裁会溢出到外面
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
