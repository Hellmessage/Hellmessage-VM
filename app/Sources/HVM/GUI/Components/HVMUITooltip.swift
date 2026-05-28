// HVMUITooltip.swift — 新 GUI 自绘 tooltip (PR-C6)
//
// 用法 (modifier on any view):
//   HVMUI.Button(icon: "trash", variant: .ghost) { ... }
//       .hvmTooltip("删除当前 VM")
//
//   HVMUI.Icon("info.circle")
//       .hvmTooltip("详细说明", edge: .leading)
//
//   image.hvmTooltip("...", kbd: "⌘+S")   // tooltip 末加键盘快捷键 chip
//
// 设计:
//   - 自绘 tooltip 卡片, 不用系统 NSTooltip (无 vibrancy, 完全自家风格)
//   - hover 500ms 延迟后出, hover off 立即收
//   - 200ms ease-out 渐入 + scale 0.95→1.0
//   - 可选 edge (位置): .top / .bottom / .leading / .trailing (默认 .top)
//   - bg = bgOverlay + borderEmphasis + radius md + 轻 shadow
//   - 不参与 layout flow (用 .overlay)
//
// 跟 SwiftUI 系统 .help() modifier 区别: .help() 是 NSTooltip 风, 风格固定;
// HVMUI.Tooltip 完全自家绘, 风格跟其他 HVMUI 组件一致.

#if NEW_GUI

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
                        .offset(offsetFromEdge)
                        .transition(.opacity.combined(with:
                            .scale(scale: 0.95, anchor: scaleAnchor)))
                        .zIndex(2000)
                        .allowsHitTesting(false)  // tooltip 不挡 trigger 自身 hit
                }
            }
            .animation(HVMTheme.motion.easeOut, value: showTooltip)
    }

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

    private var offsetFromEdge: CGSize {
        let gap: CGFloat = HVMTheme.space.sm
        switch edge {
        case .top:      return CGSize(width: 0, height: -gap - 22)
        case .bottom:   return CGSize(width: 0, height: gap + 22)
        case .leading:  return CGSize(width: -gap - 80, height: 0)
        case .trailing: return CGSize(width: gap + 80, height: 0)
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

#endif
