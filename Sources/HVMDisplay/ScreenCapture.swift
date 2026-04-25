// HVMDisplay/ScreenCapture.swift
// 从 VZVirtualMachineView 抓 frame buffer 转成 PNG 字节. 给 hvm-dbg screenshot / ocr 用.
//
// 关键点: VZ view 内部用 CAMetalLayer 渲染 guest framebuffer, 而 NSView.cacheDisplay
// 只抓 NSView 自己绘制的内容, 抓不到 sublayer 的 Metal drawable —— 截出来全黑.
// 改用 CGWindowListCreateImage 按 windowID 抓整窗口 (含所有 layer 包括 Metal), 然后
// 按 view 在 window 里的 frame 裁出来.
//
// 注: CGWindowListCreateImage 在 macOS 14.4 起被标 deprecated, 新接口走 ScreenCaptureKit
// 但要 Screen Recording 权限. 当前 API 抓自己进程的 window 仍可用且不要权限. 后续若被
// 完全移除再换 SCK + 权限请求.

import AppKit
import CryptoKit
import CoreGraphics
import Foundation

public enum ScreenCapture {
    /// 抓 view 当前 frame, 返回 PNG 字节 + 原生像素宽高 + sha256.
    /// - Returns: nil 表示 view 还未渲染 / window 无 windowNumber / 截图 API 失败
    @MainActor
    public static func capturePNG(from view: NSView) -> (data: Data, widthPx: Int, heightPx: Int, sha256: String)? {
        guard let window = view.window,
              window.windowNumber > 0,
              view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        let windowID = CGWindowID(window.windowNumber)
        // 抓整 window (含 Metal sublayer). bestResolution 拿 backing scale 后的像素图.
        guard let windowImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
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

        guard let cgImage = windowImage.cropping(to: cropRect) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let hash = SHA256.hash(data: pngData)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return (pngData, cgImage.width, cgImage.height, hex)
    }
}
