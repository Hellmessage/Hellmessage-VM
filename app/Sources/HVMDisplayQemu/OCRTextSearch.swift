// HVMDisplay/OCRTextSearch.swift
// 纯函数: 在 OCR 结果里找包含 query 的第一项. find_text 的核心.
// VZ DbgOps + QEMU QemuHostState 共用; 与 IPC 类型解耦.

import Foundation

public enum OCRTextSearch {

    /// 命中结果. 调用方按需转 IPC payload (含/不含 bbox/center).
    /// 注: OCREngine.TextItem 是 Codable Sendable 但非 Equatable, Hit 也不强行 Equatable.
    public struct Hit: Sendable {
        public let item: OCREngine.TextItem
        public init(item: OCREngine.TextItem) { self.item = item }
    }

    /// 大小写不敏感子串命中. 返回首个匹配 item; 都不命中返 nil.
    /// query 空字符串视为不命中 (调用方应先检查).
    public static func find(in items: [OCREngine.TextItem], query: String) -> Hit? {
        let needle = query.lowercased()
        if needle.isEmpty { return nil }
        guard let item = items.first(where: { $0.text.lowercased().contains(needle) }) else {
            return nil
        }
        return Hit(item: item)
    }
}
