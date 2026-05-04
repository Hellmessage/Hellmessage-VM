// HVMGuiProbe/ScreenshotRenderer.swift
// 截 HVM 主进程主窗口 (含弹层 dialog) → PNG.
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md D-G3.
//
// 实现: NSWindow.contentView 的 bitmapImageRepForCachingDisplay 渲染. 不要
// CGWindowListCreateImage (要 screen recording 权限, UX 差).

import AppKit
import Foundation
import HVMCore

@MainActor
enum ScreenshotRenderer {
    private static let log = HVMLog.logger("guiprobe.screenshot")

    /// 截当前 keyWindow / mainWindow (优先 keyWindow; 没有则 mainWindow). 失败返 nil.
    static func captureMainWindow() -> Data? {
        let win = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window = win, let contentView = window.contentView else {
            log.warning("captureMainWindow: 没有可见 window")
            return nil
        }
        return capture(view: contentView)
    }

    /// 截指定 NSView (含 SwiftUI subview / NSHostingView). 失败返 nil.
    static func capture(view: NSView) -> Data? {
        // 让 SwiftUI 子树完成布局 (避免截到旧帧)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            log.warning("capture: bounds 为空 \(NSStringFromRect(bounds), privacy: .public)")
            return nil
        }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            log.warning("capture: bitmapImageRepForCachingDisplay 返 nil")
            return nil
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            log.warning("capture: PNG encode failed")
            return nil
        }
        return png
    }
}
