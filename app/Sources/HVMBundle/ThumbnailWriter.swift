// HVMBundle/ThumbnailWriter.swift
// 缩略图 atomic 落盘 helper. VZ 路径 (HVMDisplay/ThumbnailGenerator) 和
// QEMU 路径 (HVM/QemuHostEntry) 共用, 避免重复实现 atomic replace 逻辑.
//
// 落盘策略: 写到 .thumbnail.png.tmp → replaceItemAt; 失败不留半成品.

import Foundation

public enum ThumbnailWriter {
    public enum Error: Swift.Error {
        case writeFailed(reason: String)
    }

    /// 把 PNG 数据写到 bundle/meta/thumbnail.png. 自动建 meta 目录 + atomic replace.
    /// 调用方需保证 pngData 是有效 PNG; 写盘失败抛 .writeFailed.
    public static func writeAtomic(_ pngData: Data, to bundleURL: URL) throws {
        let metaDir = BundleLayout.metaDir(bundleURL)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let target = metaDir.appendingPathComponent(BundleLayout.thumbnailName)
        let tmp = metaDir.appendingPathComponent(".\(BundleLayout.thumbnailName).tmp")
        do {
            try pngData.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw Error.writeFailed(reason: "\(error)")
        }
    }
}
