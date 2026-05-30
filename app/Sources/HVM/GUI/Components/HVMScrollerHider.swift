// HVMScrollerHider.swift — 强制隐藏 ScrollView 滚动条 (保留滚动能力).
//
// SwiftUI `.scrollIndicators(.hidden)` 在 macOS "系统设置 → 外观 → 显示滚动条 = 始终"
// 时被系统强制覆盖, 滚动条仍显示. 这里下钻 AppKit 拿到底层 NSScrollView, 直接
// hasVerticalScroller = false 隐掉 scroller — 不影响 trackpad/滚轮滚动.
//
// 纯 UI 工具 (AppKit), 不引业务. 用法: 套在 ScrollView 的 content 上 (内部), 让
// enclosingScrollView 能解析到目标 NSScrollView.
//   ScrollView { content.hvmHideScroller() }

#if NEW_GUI

import SwiftUI
import AppKit

extension View {
    func hvmHideScroller() -> some View {
        background(ScrollerHider())
    }
}

private struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        schedule(v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        schedule(nsView)
    }

    /// 多次延迟重试: ScrollView 可能在 NSView 入树后才建好 NSScrollView, 或重布局时
    /// 把 scroller 重新打开 — 多个时间点重应用兜底.
    private func schedule(_ v: NSView) {
        for delay in [0.0, 0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                disable(findScrollView(from: v))
            }
        }
    }

    /// 向上遍历 superview 链找 NSScrollView (比 enclosingScrollView 更稳, 兼容
    /// SwiftUI ScrollView 多层包装).
    private func findScrollView(from v: NSView) -> NSScrollView? {
        var cur: NSView? = v.superview
        while let c = cur {
            if let sv = c as? NSScrollView { return sv }
            cur = c.superview
        }
        return v.enclosingScrollView
    }

    private func disable(_ sv: NSScrollView?) {
        guard let sv else { return }
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.verticalScroller?.alphaValue = 0
        sv.horizontalScroller?.alphaValue = 0
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
    }
}

#endif
