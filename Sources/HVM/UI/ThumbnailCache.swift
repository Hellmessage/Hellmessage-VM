// HVM/UI/ThumbnailCache.swift
// 缩略图内存缓存. mtime invalidation + LRU 淘汰.
//
// 之前 menu bar popover 弹出时会同步 NSImage(contentsOf:) 每个运行中 VM 的 thumbnail,
// 10+ 个 VM 时会产生 200-300ms jank. 加一层 cache:
//   - 命中: 直接返图, 无 IO (热路径)
//   - mtime 变化 (snapshot 重写): 失效, 重读
//   - 不存在的文件: cache 一个 nil (避免重复 stat 失败)
//   - 容量上限 32 张, LRU 淘汰
//
// 全程在 MainActor 上调用 (popover snapshot 在 main thread 拼装), 不需要锁.

import AppKit
import Foundation

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private struct Entry {
        /// 文件 mtime; nil 表示文件不存在 (negative cache, 避免反复 stat)
        let mtime: Date?
        let image: NSImage?
    }

    private var cache: [URL: Entry] = [:]
    /// LRU 顺序: 末尾是最新访问
    private var lru: [URL] = []
    private let maxCount = 32

    private init() {}

    /// 获取缩略图. 命中且 mtime 一致直接返; 否则同步 stat + load.
    /// 调用方拿到 nil 后应该用占位 SF Symbol.
    func image(for url: URL) -> NSImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

        if let entry = cache[url], entry.mtime == mtime {
            bumpLRU(url)
            return entry.image
        }

        // miss: load
        let img: NSImage? = (mtime != nil) ? NSImage(contentsOf: url) : nil
        cache[url] = Entry(mtime: mtime, image: img)
        bumpLRU(url)
        evictIfNeeded()
        return img
    }

    /// 显式失效 (例如新生成 snapshot 后想强制下次重读); 一般不必, mtime 比对自动失效.
    func invalidate(_ url: URL) {
        cache.removeValue(forKey: url)
        lru.removeAll { $0 == url }
    }

    private func bumpLRU(_ url: URL) {
        lru.removeAll { $0 == url }
        lru.append(url)
    }

    private func evictIfNeeded() {
        while cache.count > maxCount, let oldest = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
