// HVMDisplay/ScreenCapture.swift
// 从 VZVirtualMachineView 抓 frame buffer 转成 PNG 字节. 给 hvm-dbg screenshot / ocr 用.
//
// 关键点: VZ view 内部用 CAMetalLayer 渲染 guest framebuffer, 而 NSView.cacheDisplay
// 只抓 NSView 自己绘制的内容, 抓不到 sublayer 的 Metal drawable —— 截出来全黑.
// 改用 CGWindowListCreateImage 按 windowID 抓整窗口 (含所有 layer 包括 Metal), 然后
// 按 view 在 window 里的 frame 裁出来.
//
// 注: CGWindowListCreateImage 在 macOS 14 起被标 deprecated, 新接口走 ScreenCaptureKit
// 但要 Screen Recording 权限. 当前 API 抓自己进程的 window 仍可用且不要权限. 后续若被
// 完全移除再换 SCK + 权限请求. 用 @_silgen_name 直接绑 C 符号绕过 Swift 的 deprecation
// 警告 — 这条路径是有意保留的, 不是疏忽.

import AppKit
import CoreGraphics
import Foundation
import HVMUtils

@_silgen_name("CGWindowListCreateImage")
private func _hvmCGWindowListCreateImage(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> Unmanaged<CGImage>?

public enum ScreenCapture {
    /// 抓 view 当前 frame, 返回 PNG 字节 + 像素宽高 + sha256.
    /// - Parameters:
    ///   - view: 待截 NSView, 必须 attach 到 window
    ///   - maxEdge: 输出图最长边像素上限. 超出按比例 downscale (高质量插值).
    ///              nil = 不缩放, 保留 backing scale 原分辨率 (OCR/find-text 用).
    ///              典型场景: 给 Claude API 的截图传 1568, 既符合 many-image 2000px 上限
    ///              又是 Anthropic 推荐尺寸.
    /// - Returns: nil 表示 view 还未渲染 / window 无 windowNumber / 截图 API 失败
    @MainActor
    public static func capturePNG(from view: NSView, maxEdge: Int? = nil) -> (data: Data, widthPx: Int, heightPx: Int, sha256: String)? {
        guard let window = view.window,
              window.windowNumber > 0,
              view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        let windowID = CGWindowID(window.windowNumber)
        // 抓整 window (含 Metal sublayer). bestResolution 拿 backing scale 后的像素图.
        guard let windowImage = _hvmCGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )?.takeRetainedValue() else {
            return nil
        }

        // view 在 window 里的位置 (AppKit 左下原点 → CGImage 左上原点要翻转)
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let windowHeight = window.frame.height
        // backing scale: window image 的像素和 window points 的比例
        let scale = CGFloat(windowImage.width) / window.frame.width
        let cropRect = CGRect(
            x:      viewFrameInWindow.origin.x * scale,
            y:      (windowHeight - viewFrameInWindow.maxY) * scale,
            width:  viewFrameInWindow.width  * scale,
            height: viewFrameInWindow.height * scale
        )

        guard var cgImage = windowImage.cropping(to: cropRect) else {
            return nil
        }

        if let maxEdge = maxEdge, max(cgImage.width, cgImage.height) > maxEdge {
            if let scaled = downscale(cgImage, maxEdge: maxEdge) {
                cgImage = scaled
            }
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let hex = Hashing.sha256Hex(pngData)
        return (pngData, cgImage.width, cgImage.height, hex)
    }

    /// 按最长边等比缩放. 失败返回 nil 让调用方走原图.
    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let ratio = CGFloat(maxEdge) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(w) * ratio).rounded()))
        let newH = max(1, Int((CGFloat(h) * ratio).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}
