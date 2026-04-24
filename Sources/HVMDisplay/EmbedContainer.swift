// EmbedContainer.swift
// 主窗口右栏嵌入态容器. 使用同一个 HVMView 实例在独立窗口 / 嵌入之间 reparent,
// 保证 VZVirtualMachine 不被重建, guest 无感知切换.
// 详见 docs/GUI.md "嵌入态"

import SwiftUI
import AppKit

/// 管理一个 HVMView 在多个 NSView 容器之间的 reparent
public final class ViewAttachment {
    public let view: HVMView

    public init(view: HVMView) {
        self.view = view
    }

    /// 把 view 挪到新 superview. 旧 superview 若存在会自动 removeFromSuperview.
    @MainActor
    public func attach(to superview: NSView) {
        view.removeFromSuperview()
        view.frame = superview.bounds
        view.autoresizingMask = [.width, .height]
        superview.addSubview(view)
    }

    @MainActor
    public func detach() {
        view.removeFromSuperview()
    }
}

/// SwiftUI 视图, 在嵌入态展示给定 ViewAttachment 的 HVMView.
/// 内部用 NSViewRepresentable 承载一个空白 container, 再把 attachment reparent 进去.
public struct EmbeddedVMContent: NSViewRepresentable {
    let attachment: ViewAttachment

    public init(attachment: ViewAttachment) {
        self.attachment = attachment
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attachment.attach(to: container)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // reparent 幂等: 若 attachment 的 view 已经是本 container 的子视图, attach 内部 removeFromSuperview 再 add 也不出错
        if attachment.view.superview !== nsView {
            attachment.attach(to: nsView)
        }
    }
}
