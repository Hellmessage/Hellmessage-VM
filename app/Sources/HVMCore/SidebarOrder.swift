// HVMCore/SidebarOrder.swift
// Sidebar VM 列表的用户自定义顺序持久化.
//
// 文件位置: ~/Library/Application Support/HVM/sidebar-order.json
// 内容格式: { "version": 1, "ids": ["<uuid>", "<uuid>", ...] }
//
// 设计要点:
// - 与 routing JSON / config.yaml 解耦, 不污染现有 VM 元数据
// - load 容错: 文件不存在 / JSON 损坏 → 返回空数组, 走 displayName 排序
// - save 是覆盖写, 调用方负责传完整顺序数组
// - apply(...) helper 把存储顺序套到当前 list 上: 已知 ID 按存储顺序排前面,
//   未知 ID (新 VM / 文件没记录的) 按 displayName 排后面追加
//
// 不做的:
// - 跨机器同步 (顺序是用户本机偏好, 无 portable 需求)
// - 顺序变更历史 (覆盖写, 不留 audit log)

import Foundation

public enum SidebarOrder {

    private static var storeURL: URL {
        HVMPaths.appSupport.appendingPathComponent("sidebar-order.json", isDirectory: false)
    }

    public struct Stored: Codable {
        public let version: Int
        public var ids: [String]
        public init(version: Int = 1, ids: [String]) {
            self.version = version
            self.ids = ids
        }
    }

    /// 读当前存储顺序. 文件不存在 / JSON 损坏 → 返回空数组.
    public static func load() -> [UUID] {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return []
        }
        return stored.ids.compactMap { UUID(uuidString: $0) }
    }

    /// 覆盖写当前顺序. 调用方传完整顺序数组.
    /// 父目录不存在自动创建. 写入失败不抛 (让 UI 行为不被磁盘问题阻断).
    public static func save(_ ids: [UUID]) {
        let stored = Stored(ids: ids.map { $0.uuidString.lowercased() })
        do {
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // 静默失败 — 顺序丢失不影响功能, 下次启动按 displayName 排序兜底
        }
    }

    /// 把存储顺序套到一组 VMListItem 上.
    /// - 存储顺序中存在且 list 中能找到的, 按存储顺序排在前面
    /// - list 中有但存储顺序中没有的, 按 displayName 排在后面追加 (新创建 VM 落末尾)
    /// - 存储顺序中有但 list 中找不到的 ID, 直接忽略 (delete 后会自然消失, 下次 save 时清掉)
    public static func apply<T>(_ items: [T], idOf: (T) -> UUID, nameOf: (T) -> String) -> [T] {
        let stored = load()
        let storedSet = Set(stored)
        var byID: [UUID: T] = [:]
        for it in items { byID[idOf(it)] = it }

        var ordered: [T] = []
        for id in stored {
            if let it = byID[id] { ordered.append(it) }
        }
        let leftovers = items
            .filter { !storedSet.contains(idOf($0)) }
            .sorted { nameOf($0).lowercased() < nameOf($1).lowercased() }
        ordered.append(contentsOf: leftovers)
        return ordered
    }
}
