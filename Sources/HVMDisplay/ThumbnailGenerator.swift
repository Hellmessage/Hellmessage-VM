// ThumbnailGenerator.swift
// 从 HVMView 截图生成缩略图并写入 bundle/meta/thumbnail.png
// 仅在 view 已添加到 window 且至少渲染过一帧时有效 (CALayer 已 flush)

import AppKit
import Foundation
import HVMBundle

public enum ThumbnailGenerator {
    /// 目标缩略图尺寸 (docs/VM_BUNDLE.md: 512×320)
    public static let targetSize = NSSize(width: 512, height: 320)

    /// 从 view 截当前 frame buffer, 缩放并以 PNG 落盘到 bundle/meta/thumbnail.png.
    /// 失败返回 false 并不写文件.
    @MainActor
    @discardableResult
    public static func capture(from view: NSView, to bundleURL: URL) -> Bool {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
            return false
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // 缩放: 按短边等比缩至 target
        let srcSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard srcSize.width > 0, srcSize.height > 0 else { return false }
        let scale = min(targetSize.width / srcSize.width,
                        targetSize.height / srcSize.height)
        let outSize = NSSize(width: srcSize.width * scale,
                             height: srcSize.height * scale)

        let outImage = NSImage(size: outSize)
        outImage.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: outSize).fill()
        rep.draw(in: NSRect(origin: .zero, size: outSize))
        outImage.unlockFocus()

        guard let tiff = outImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        let metaDir = BundleLayout.metaDir(bundleURL)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let target = metaDir.appendingPathComponent(BundleLayout.thumbnailName)
        do {
            let tmp = target.deletingLastPathComponent()
                .appendingPathComponent(".\(BundleLayout.thumbnailName).tmp")
            try pngData.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
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
