// EmbedContainer.swift
// SwiftUI 把 HVMView 作为 NSViewRepresentable 的 NSView 直接暴露给 hosting,
// 不再包 container 中间层, 避免 SwiftUI 在 layout 过程中对 container 做
// detach/reattach 进而让 HVMView 离开 window hierarchy (Metal drawable 失效).
//
// VMSession.attachment 保留, 但不再做 reparent — M2 嵌入 only, 单窗口足够.

import SwiftUI
import AppKit

/// 共享 HVMView 的引用容器. VMSession 里与 SwiftUI View 共同持有一份.
public final class ViewAttachment {
    public let view: HVMView

    public init(view: HVMView) {
        self.view = view
    }

    /// 显式从当前 superview 脱离 (cleanup 时调). 此后 SwiftUI 若 re-host 会重新 attach.
    @MainActor
    public func detach() {
        view.removeFromSuperview()
    }
}

/// SwiftUI 直接暴露 HVMView, 让 SwiftUI 的 NSHostingView 管理 view 的 window lifecycle.
public struct EmbeddedVMContent: NSViewRepresentable {
    let attachment: ViewAttachment

    public init(attachment: ViewAttachment) {
        self.attachment = attachment
    }

    public func makeNSView(context: Context) -> HVMView {
        attachment.view
    }

    public func updateNSView(_ nsView: HVMView, context: Context) {
        // 不动, SwiftUI 维护 view 的父子关系
    }
}
