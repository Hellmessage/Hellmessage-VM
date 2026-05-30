// HVMScrollerHider.swift — 强制隐藏 ScrollView 滚动条 (保留滚动, 且不预留空间).
//
// 两个问题一起解:
//   1. 滚动条可见: macOS "系统设置 → 显示滚动条 = 始终" 下, .scrollIndicators(.hidden) 无效,
//      系统强制显 legacy 滚动条.
//   2. 滚动条占位: legacy 滚动条会在内容区右侧预留 ~15px (即使隐藏 scroller). 窗口变小内容
//      变可滚动时 SwiftUI 重新启用 legacy 滚动条, 预留空间残留 → 右侧出现空白.
//
// 解法: `scrollerStyle = .overlay` (浮动式, 永不预留空间) + hasVerticalScroller = false
// (不显 scroller). 并监听 NSScrollView frame 变化, resize 时重新应用 (防 SwiftUI 重布局
// 把 style 改回 legacy 又预留空间).
//
// 纯 UI 工具 (AppKit), 不引业务. 用法: ScrollView { content.hvmHideScroller() }


import SwiftUI
import AppKit

extension View {
    func hvmHideScroller() -> some View {
        background(ScrollerHider())
    }
}

private struct ScrollerHider: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    // 只在主线程用 (NSViewRepresentable 回调 + main 队列 + 主线程通知); @unchecked Sendable
    // 让捕进 DispatchQueue 闭包不报数据竞争. NSObject 让 @objc 通知 selector 可用.
    final class Coordinator: NSObject, @unchecked Sendable {
        private weak var scrollView: NSScrollView?

        func attach(to v: NSView) {
            DispatchQueue.main.async { [weak self] in
                // DispatchQueue.main 上即主线程, assumeIsolated 让下方访问 main-actor NSView 属性合法
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let sv = self.findScrollView(from: v) else {
                        // ScrollView 可能还没建好 NSScrollView, 短延迟重试
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.attach(to: v) }
                        return
                    }
                    if self.scrollView !== sv {
                        self.scrollView = sv
                        sv.postsFrameChangedNotifications = true
                        NotificationCenter.default.addObserver(
                            self, selector: #selector(self.reapply),
                            name: NSView.frameDidChangeNotification, object: sv)
                    }
                    self.apply(sv)
                }
            }
        }

        @MainActor @objc private func reapply() {
            if let sv = scrollView { apply(sv) }
        }

        /// overlay 是关键: 浮动滚动条永不在内容区预留空间; hasVerticalScroller=false 进一步不显.
        @MainActor private func apply(_ sv: NSScrollView) {
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScroller?.alphaValue = 0
            sv.horizontalScroller?.alphaValue = 0
        }

        @MainActor private func findScrollView(from v: NSView) -> NSScrollView? {
            var cur: NSView? = v.superview
            while let c = cur {
                if let sv = c as? NSScrollView { return sv }
                cur = c.superview
            }
            return v.enclosingScrollView
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

