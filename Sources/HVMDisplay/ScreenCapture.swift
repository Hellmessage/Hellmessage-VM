// HVMDisplay/ScreenCapture.swift
// 从 VZVirtualMachineView 抓 frame buffer 转成 PNG 字节. 给 hvm-dbg screenshot / ocr 用.
// 与 ThumbnailGenerator 区别: 不缩放, 输出原生像素分辨率, 不落盘.
//
// 限制 (与 ThumbnailGenerator 同):
//   - view 必须已加到 window 且至少渲染过一帧 (CALayer 已 flush)
//   - VZ 没公开 frame buffer API, 走 AppKit cacheDisplay 路径

import AppKit
import CryptoKit
import Foundation

public enum ScreenCapture {
    /// 抓 view 当前 frame, 返回 PNG 字节 + 原生像素宽高 + sha256.
    /// - Returns: nil 表示 view 还未渲染 / 无效
    @MainActor
    public static func capturePNG(from view: NSView) -> (data: Data, widthPx: Int, heightPx: Int, sha256: String)? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let hash = SHA256.hash(data: pngData)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return (pngData, rep.pixelsWide, rep.pixelsHigh, hex)
    }
}
