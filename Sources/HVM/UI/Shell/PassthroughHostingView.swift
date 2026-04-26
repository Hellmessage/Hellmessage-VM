// PassthroughHostingView.swift
// 用于"全覆盖叠加层"的 NSHostingView 子类:
// 当鼠标点在透明区域 (SwiftUI 内容没有任何可命中的 view), 返回 nil
// 让事件穿透到下层的 NSView (sidebar / detail / toolbar 等).
//
// 普通 NSHostingView 即使 SwiftUI 内容 allowsHitTesting(false), 自身这个 NSView
// 仍然 absorb 鼠标事件, 导致 overlay 上方的所有点击全部失效.

import AppKit
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// 弹窗激活时, 在整块 overlay bounds 上加一个 .arrow cursor rect,
    /// 压过下层 VZVirtualMachineView 的隐藏光标 rect, 否则鼠标落在 dialog 上方
    /// 仍会因为 VZ view 的 cursor rect 生效而看不到光标.
    /// 这个标志 timing 不敏感 (cursor rect 重算在每次进入 view 时), 用 didSet 异步更新足够.
    var dialogActive: Bool = false {
        didSet {
            guard dialogActive != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// hitTest 用的实时检测 closure. 由 caller 注入, 内部直接读 model/errors/confirms.current,
    /// 避开 withObservationTracking 的异步 onChange 延迟 — 否则 .terminateLater 这种
    /// "AppKit 等 reply 时同步触发 dialog" 的场景, dialogActive 来不及更新, 整块 overlay
    /// 被当透明区, dialog 里的按钮点不动.
    var isAnyDialogActive: @MainActor () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        // 弹窗激活时整个 overlay 都不 passthrough:
        // NSHostingView 对 SwiftUI button/TextField 等可交互区往往直接返回 self (不暴露
        // 深层 NSView), 旧的 v === self → nil 会把这些命中误判成"透明区"穿透下去, dialog
        // 按钮全失效. dialog 内的 dimmer 已用 .allowsHitTesting(false), SwiftUI 自身处理.
        if MainActor.assumeIsolated({ isAnyDialogActive() }) { return v }
        // 没弹窗: 命中 self 表示鼠标落在 SwiftUI 透明区域, 返回 nil 让事件穿透到下层 NSView
        return v === self ? nil : v
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if dialogActive {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}
