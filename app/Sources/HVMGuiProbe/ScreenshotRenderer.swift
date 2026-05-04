// HVMGuiProbe/ScreenshotRenderer.swift
// 截 HVM 主进程主窗口 (含弹层 dialog) → PNG.
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md D-G3.
//
// 实现:
//   1. 用 NSView.bitmapImageRepForCachingDisplay 渲染主 contentView (SwiftUI 普通绘制)
//      → 不要 CGWindowListCreateImage (要 screen recording 权限, UX 差).
//   2. **bitmapImageRepForCachingDisplay 不能抓 Metal-backed view 的 IOSurface 内容**
//      (MTKView / FramebufferHostView 在主截图里是黑块). 必须遍历 subview tree 找
//      FramebufferHostView, 调它 renderer.snapshotCGImage 拿 BGRA framebuffer CGImage,
//      用 CGContext 合成到对应 rect 上, 再 PNG encode.

import AppKit
import Foundation
import CoreGraphics
import HVMCore
import HVMDisplayQemu

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

        // 找所有嵌入的 FramebufferHostView (MTKView), 把它们当前帧合成上去.
        // bitmapImageRepForCachingDisplay 走 NSView CALayer cache 通路, 不抓 Metal
        // drawable → 这些 view 截出来是 clearColor 黑块. 必须自己用 renderer.snapshotCGImage
        // 拿 BGRA framebuffer 后用 CGContext draw 进去.
        let fbViews = collectFramebufferViews(in: view)
        let finalRep: NSBitmapImageRep
        if !fbViews.isEmpty, let composited = composite(rep: rep, root: view, framebufferViews: fbViews) {
            finalRep = composited
        } else {
            finalRep = rep
        }

        guard let png = finalRep.representation(using: .png, properties: [:]) else {
            log.warning("capture: PNG encode failed")
            return nil
        }
        return png
    }

    /// 递归遍历 subview tree 收所有 FramebufferHostView. 顶层 contentView 可能含
    /// NSHostingView (SwiftUI bridge), 内部嵌 FramebufferHostView, 嵌套层级不固定.
    private static func collectFramebufferViews(in root: NSView) -> [FramebufferHostView] {
        var found: [FramebufferHostView] = []
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let fb = v as? FramebufferHostView {
                found.append(fb)
            }
            stack.append(contentsOf: v.subviews)
        }
        return found
    }

    /// 把 framebufferViews 当前帧 draw 到 rep 对应位置, 返回新 rep. nil = 创建 CGContext / 转换失败.
    private static func composite(rep: NSBitmapImageRep,
                                   root: NSView,
                                   framebufferViews: [FramebufferHostView]) -> NSBitmapImageRep? {
        // rep pixelsWide/pixelsHigh 是 backing pixel 尺寸 (含 retina scale);
        // root.bounds 是 point 尺寸. 比例 = pixelsWide / bounds.width.
        let pixelW = rep.pixelsWide
        let pixelH = rep.pixelsHigh
        guard pixelW > 0, pixelH > 0 else { return nil }
        let scaleX = CGFloat(pixelW) / root.bounds.width
        let scaleY = CGFloat(pixelH) / root.bounds.height

        // 把 rep 转 CGImage 拿基底 — 复用现有截图 (含 SwiftUI chrome / 文字 / 按钮 etc),
        // 然后 在新 CGContext 上铺这张基底 + 覆盖 framebuffer.
        guard let baseCG = rep.cgImage else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
                         CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil,
                                   width: pixelW,
                                   height: pixelH,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 0,
                                   space: cs,
                                   bitmapInfo: bitmapInfo) else {
            return nil
        }

        // 1. 铺基底 (整张 SwiftUI 截图).
        ctx.draw(baseCG, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // 2. 覆盖 framebuffer.
        for fb in framebufferViews {
            guard let fbImage = fb.renderer.snapshotCGImage() else { continue }
            // FramebufferHostView 在 root 内的 frame (point 单位, root 坐标系).
            let frameInRoot = fb.convert(fb.bounds, to: root)
            // 转成 pixel 单位 + AppKit→CoreGraphics y-flip (rep 原点左下, root.convert 是
            // root 自家坐标系, root 是 NSView 默认左下原点 → 需要把 y 翻转成 CG context
            // 的 "左下原点 像素" 对应位置).
            // root 是 NSView 默认 .isFlipped == false → root 自家坐标 y 向上;
            // 我们 CGContext 也是默认 y 向上 → 不需要 flip, 直接乘 scale.
            // 但: AppKit subview convert 出来的 frame y=0 在 root 底部. CGImage 画进
            // CGContext 时, 默认 y=0 也是 context 底部. 一致, 不需要 flip.
            let pixelRect = CGRect(
                x: frameInRoot.origin.x * scaleX,
                y: frameInRoot.origin.y * scaleY,
                width: frameInRoot.width * scaleX,
                height: frameInRoot.height * scaleY
            )
            // 居中 letterbox: framebuffer 像素尺寸 vs view rect 比例不一定一样,
            // FramebufferRenderer.draw 走 min(scale_x, scale_y) 等比 + 居中,
            // 这里同样实现一遍, 让截图视觉跟用户实际看到的一致.
            let fbW = CGFloat(fbImage.width)
            let fbH = CGFloat(fbImage.height)
            let fitScale = min(pixelRect.width / fbW, pixelRect.height / fbH)
            let drawW = fbW * fitScale
            let drawH = fbH * fitScale
            let drawX = pixelRect.origin.x + (pixelRect.width  - drawW) * 0.5
            let drawY = pixelRect.origin.y + (pixelRect.height - drawH) * 0.5
            ctx.draw(fbImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }

        guard let outCG = ctx.makeImage() else { return nil }
        let outRep = NSBitmapImageRep(cgImage: outCG)
        return outRep
    }
}
