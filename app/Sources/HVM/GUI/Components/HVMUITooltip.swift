// HVMUITooltip.swift — 新 GUI 自绘 tooltip (不用系统 NSTooltip, 完全自家风格).
//
// hover 500ms 延迟后出, hover off 立即收; edge 控位置 (.top default / .bottom / .leading / .trailing).
// 不参与 layout flow (用 .overlay). 可选 kbd 末加键盘快捷键 chip.
// 用法: view.hvmTooltip("删除当前 VM") / view.hvmTooltip("...", edge: .leading, kbd: "⌘+S")


import SwiftUI

extension HVMUI {

/// 内部 tooltip view — 业务侧用 .hvmTooltip(_:) modifier 触发.
fileprivate struct TooltipContent: View {
    let text: String
    let kbd: String?

    var body: some View {
        HStack(spacing: HVMTheme.space.sm) {
            SwiftUI.Text(text)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let kbd {
                HVMUI.KbdHint(kbd, size: .sm)
            }
        }
        .padding(.horizontal, HVMTheme.space.md)
        .padding(.vertical, HVMTheme.space.sm)
        .background(
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .fill(HVMTheme.color.bgOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                        .stroke(HVMTheme.color.borderEmphasis,
                                lineWidth: HVMTheme.border.hairline)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

/// hover 500ms delay 显示 + 200ms 渐入 + 自家定位. 业务侧用 .hvmTooltip(...) 触发.
fileprivate struct TooltipModifier: ViewModifier {
    let text: String
    let edge: Edge
    let kbd: String?

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var pendingTask: Task<Void, Never>?
    @State private var tooltipSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovered = hovering
                pendingTask?.cancel()
                if hovering {
                    // 500ms 延迟后显示, 防鼠标快速划过时 tooltip 抖动
                    pendingTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if !Task.isCancelled && isHovered {
                            await MainActor.run { showTooltip = true }
                        }
                    }
                } else {
                    showTooltip = false
                }
            }
            .overlay(alignment: overlayAlignment) {
                if showTooltip {
                    TooltipContent(text: text, kbd: kbd)
                        .fixedSize()
                        // GeometryReader 拿 tooltip 实际渲染 size 上传 @State
                        // (PreferenceKey 跨 overlay 边界不触发, 用 onAppear/onChange)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { tooltipSize = proxy.size }
                                    .onChange(of: proxy.size) { _, new in
                                        tooltipSize = new
                                    }
                            }
                        )
                        // offset 用 tooltipSize 把 tooltip 推出 trigger 外侧 + gap
                        // (首帧 size=0 重叠一闪, 第二帧跳到正确位置, 可接受)
                        .offset(offsetForEdge)
                        .transition(.opacity.combined(with:
                            .scale(scale: 0.95, anchor: scaleAnchor)))
                        .zIndex(2000)
                        .allowsHitTesting(false)
                }
            }
            .animation(HVMTheme.motion.easeOut, value: showTooltip)
            .animation(HVMTheme.motion.easeOut, value: tooltipSize)
    }

    private var tooltipGap: CGFloat { HVMTheme.space.sm }

    private var overlayAlignment: Alignment {
        switch edge {
        case .top:      return .top
        case .bottom:   return .bottom
        case .leading:  return .leading
        case .trailing: return .trailing
        }
    }

    private var scaleAnchor: UnitPoint {
        switch edge {
        case .top:      return .bottom
        case .bottom:   return .top
        case .leading:  return .trailing
        case .trailing: return .leading
        }
    }

    /// 用 tooltip 实际 size 算 offset, 沿 edge 反方向推出 tooltipSize + gap.
    private var offsetForEdge: CGSize {
        switch edge {
        case .top:
            return CGSize(width: 0, height: -tooltipSize.height - tooltipGap)
        case .bottom:
            return CGSize(width: 0, height: tooltipSize.height + tooltipGap)
        case .leading:
            return CGSize(width: -tooltipSize.width - tooltipGap, height: 0)
        case .trailing:
            return CGSize(width: tooltipSize.width + tooltipGap, height: 0)
        }
    }
}

}  // extension HVMUI 结束

extension View {
    /// 给任意 view 加 HVMUI tooltip. hover 500ms 后显示, hover off 立即隐.
    /// edge 控制 tooltip 出现位置 (.top default / .bottom / .leading / .trailing).
    /// kbd 可选: 在 tooltip 末加键盘快捷键 chip (例 "⌘+S").
    func hvmTooltip(_ text: String,
                    edge: Edge = .top,
                    kbd: String? = nil) -> some View {
        modifier(HVMUI.TooltipModifier(text: text, edge: edge, kbd: kbd))
    }
}

