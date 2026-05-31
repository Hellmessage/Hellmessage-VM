// QemuFramebufferView.swift — 新 GUI 详情区 QEMU 画面嵌入.
//
// SwiftUI ↔ AppKit 桥: NSViewRepresentable 包稳定 container NSView, 内挂 FramebufferHostView (MTKView).
// 关键纪律: Coordinator 持 fbView, makeNSView 只建一次, updateNSView 不重建 (防 Metal drawable 断).
//
// dialog z-order 防穿透: CAMetalLayer 不尊重 AppKit sibling z-order, dialog 活时叠不透明遮罩 +
// isPaused + inputCaptureEnabled=false (三保险).

import SwiftUI
import AppKit
import HVMControl
import HVMDisplayQemu

struct QemuFramebufferView: NSViewRepresentable {
    let vm: VMSummary
    let store: NewGUIStore
    /// dialog 活时暂停画面 + 叠遮罩 (防 Metal 层穿透盖住 dialog)
    let dialogPresenting: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let fb = FramebufferHostView(frame: .zero)
        fb.translatesAutoresizingMaskIntoConstraints = false
        fb.macStyleShortcuts = vm.config?.macStyleShortcuts ?? true
        container.addSubview(fb)
        NSLayoutConstraint.activate([
            fb.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fb.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fb.topAnchor.constraint(equalTo: container.topAnchor),
            fb.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // dialog 遮罩 (默认隐藏; 叠在 fb 之上)
        let mask = NSView(frame: .zero)
        mask.translatesAutoresizingMaskIntoConstraints = false
        mask.wantsLayer = true
        mask.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        mask.isHidden = true
        container.addSubview(mask)
        NSLayoutConstraint.activate([
            mask.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mask.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mask.topAnchor.constraint(equalTo: container.topAnchor),
            mask.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.fbView = fb
        context.coordinator.maskView = mask

        // 注册到 fanout (resize master: 详情区是唯一 view, 拖窗口改 guest 分辨率)
        let session = store.ensureQemuFanout(vm)
        session.addSubscriber(fb, isResizeMaster: true)
        // 文件拖拽 / Cmd+V 文件粘贴 → IPC clipboard.paste-files (走 vdagent file_xfer, 落 guest ~/Downloads).
        // FramebufferHostView 已实现 drag-drop + Cmd+V 拦截, 这里补上 onFilePaste 接线 (原 F3).
        fb.onFilePaste = { [weak session] urls in session?.sendPasteFiles(urls) }

        applyDialogState(context.coordinator, presenting: dialogPresenting)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyDialogState(context.coordinator, presenting: dialogPresenting)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func applyDialogState(_ coord: Coordinator, presenting: Bool) {
        coord.maskView?.isHidden = !presenting
        coord.fbView?.isPaused = presenting
        coord.fbView?.inputCaptureEnabled = !presenting
    }

    @MainActor
    final class Coordinator {
        var fbView: FramebufferHostView?
        var maskView: NSView?

        /// view 被 SwiftUI 移除时 (切配置 tab / 停机) 清理: fbView 摘 superview 释放 mmap 引用.
        func detach() {
            fbView?.removeFromSuperview()
            fbView = nil
            maskView = nil
        }
    }
}
