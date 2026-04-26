// HVMPopupPanel.swift
// 自绘下拉/浮起列表的承载层. 基于 AppKit NSPanel:
//   - borderless / nonactivating / floating
//   - addChildWindow 挂主窗口, 主窗口移动 panel 跟随
//   - 不在 SwiftUI 视图树, 因此不撑大父容器, 不被 ScrollView / clipShape 裁切
//   - 全局 + 本地 mouse monitor 检测点击外部 → 关闭
//   - ESC 关闭
//
// 定位策略: 通过调用方传入的 anchor NSView 直接拿 window/screen frame, 不依赖
// SwiftUI .frame(in: .global) 的坐标解释 (在嵌套 NSHostingView 场景下偏移). 由
// HVMFormSelect 用 NSViewRepresentable 在 trigger .background 挂一个不可见 anchor view.
//
// HVMFormSelect 是当前唯一调用方; 后续如要做"自绘 popover"复用即可.
//
// 注意: 这是组件实现细节, 不构成"业务侧用 popover" — CLAUDE.md UI 控件约束里
// 的"禁止业务侧用 .popover() / NSPopover"指业务文件 (Dialogs / Content / Shell),
// Style 层组件内部使用属于实现选择.

import AppKit
import SwiftUI

@MainActor
final class HVMPopupPanel {
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onDismiss: (() -> Void)?

    /// 弹出. anchor 是 trigger view (一般在 trigger .background 挂的不可见 NSView),
    /// panel 紧贴 anchor 下边缘. content 高度由 NSHostingView fittingSize 决定 (clamp 到 maxHeight).
    func present<Content: View>(
        anchor: NSView,
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content,
        onDismiss: @escaping () -> Void
    ) {
        dismiss(invokeCallback: false)
        guard let parentWindow = anchor.window else { return }
        self.onDismiss = onDismiss

        // anchor 在 window 内的 frame (NSWindow 坐标系, bottom-up)
        let triggerInWindow = anchor.convert(anchor.bounds, to: nil)
        // 转 screen 坐标 (同样 bottom-up)
        let triggerOnScreen = parentWindow.convertToScreen(triggerInWindow)

        // 自适应高度: 让 hosting view 在固定宽度 (= trigger 宽度) 下回报 fittingSize
        let width = triggerOnScreen.width
        let hosting = NSHostingView(rootView: AnyView(content().frame(width: width)))
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let panelHeight = max(40, min(fitting.height, maxHeight))
        let panelSize = CGSize(width: width, height: panelHeight)

        // panel 紧贴 anchor 下边: anchor.bottom_screenY - panelHeight
        // (NSPanel origin 是 panel 左下角, screen y 越小越往下)
        var origin = NSPoint(
            x: triggerOnScreen.minX,
            y: triggerOnScreen.minY - panelHeight
        )
        // 屏幕底部空间不够时翻到 anchor 上方紧贴
        if let screen = parentWindow.screen, origin.y < screen.visibleFrame.minY + 4 {
            origin.y = triggerOnScreen.maxY
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        panel.acceptsMouseMovedEvents = true

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()

        self.panel = panel
        installEventMonitors()
    }

    func dismiss() {
        dismiss(invokeCallback: true)
    }

    private func dismiss(invokeCallback: Bool) {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
        if invokeCallback {
            let cb = onDismiss
            onDismiss = nil
            cb?()
        } else {
            onDismiss = nil
        }
    }

    private func installEventMonitors() {
        // 切到其他 app 窗口, 关闭
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        // 同 app 内点击 / 键盘
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // ESC
                    Task { @MainActor in self.dismiss() }
                    return nil
                }
                return event
            }
            // 点击在 panel 外 → 关闭, 不吞事件 (让目标响应)
            if event.window != self.panel {
                Task { @MainActor in self.dismiss() }
            }
            return event
        }
    }
}

/// HVMFormSelect 用的 anchor view. 1×1 透明 NSView 挂在 trigger .background, 提供 popup 定位锚点.
struct HVMAnchorView: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    /// 调用方持有 ref, popup 时通过 ref.view 拿到 NSView
    let ref: Holder

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        ref.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        ref.view = nsView
    }
}
