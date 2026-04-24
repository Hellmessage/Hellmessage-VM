// HVMBundle/BundleDiscovery.swift
// 从默认 VM 目录枚举 bundle, 为 hvm-cli list 提供输入

import Foundation
import HVMCore

public enum BundleDiscovery {
    /// 列出指定目录下所有 .hvmz 目录 (一级, 不递归)
    public static func list(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let items = try fm.contentsOfDirectory(at: root,
                                               includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])
        return items.filter { $0.pathExtension == "hvmz" }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    /// 按名字 / 路径解析 bundle URL.
    /// 解析顺序:
    ///   1. 绝对路径 (或含 /) 直接返回
    ///   2. 相对当前工作目录查找 "<ref>" 或 "<ref>.hvmz"
    ///   3. 在 defaultRoot 下查 "<ref>.hvmz"
    public static func resolve(reference ref: String, defaultRoot: URL) -> URL? {
        let fm = FileManager.default

        // 1. 显式路径
        if ref.hasPrefix("/") || ref.contains("/") {
            let url = URL(fileURLWithPath: ref)
            if fm.fileExists(atPath: url.path) { return url }
            let withExt = url.deletingPathExtension().appendingPathExtension("hvmz")
            if fm.fileExists(atPath: withExt.path) { return withExt }
            return nil
        }

        // 2. 当前目录
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let rel = cwd.appendingPathComponent(ref.hasSuffix(".hvmz") ? ref : "\(ref).hvmz")
        if fm.fileExists(atPath: rel.path) { return rel }

        // 3. 默认目录
        let defaultURL = defaultRoot.appendingPathComponent(ref.hasSuffix(".hvmz") ? ref : "\(ref).hvmz")
        if fm.fileExists(atPath: defaultURL.path) { return defaultURL }

        return nil
    }
}
