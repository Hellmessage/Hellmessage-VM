// ThumbnailGenerator.swift
// 从 HVMView 截图生成缩略图并写入 bundle/meta/thumbnail.png.
//
// 关键: VZ view 用 CAMetalLayer 渲染 guest framebuffer, NSView.cacheDisplay 抓不到 sublayer
// 的 Metal drawable, 截出来全黑 (跟 hvm-dbg screenshot 当年踩过同一个坑, 见 commit c3f7096).
// 所以这里不自己截, 直接复用 ScreenCapture.capturePNG (内部走 CGWindowListCreateImage 能抓
// Metal layer). maxEdge 跟 docs/VM_BUNDLE.md 的 thumbnail 目标尺寸一致 (HVMScreenshot.thumbnailMaxEdge).

import AppKit
import Foundation
import HVMBundle
import HVMCore

public enum ThumbnailGenerator {
    /// 从 view 截当前 frame buffer, 缩放并以 PNG 落盘到 bundle/meta/thumbnail.png.
    /// 失败返回 false 并不写文件.
    @MainActor
    @discardableResult
    public static func capture(from view: NSView, to bundleURL: URL) -> Bool {
        guard let shot = ScreenCapture.capturePNG(from: view, maxEdge: HVMScreenshot.thumbnailMaxEdge) else {
            return false
        }
        do {
            try ThumbnailWriter.writeAtomic(shot.data, to: bundleURL)
            return true
        } catch {
            return false
        }
    }

    /// 读取 bundle/meta/thumbnail.png; 不存在返回 nil
    public static func load(from bundleURL: URL) -> NSImage? {
        let path = BundleLayout.metaDir(bundleURL)
            .appendingPathComponent(BundleLayout.thumbnailName).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
