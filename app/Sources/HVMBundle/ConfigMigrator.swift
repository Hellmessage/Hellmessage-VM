// HVMBundle/ConfigMigrator.swift
// VMConfig 跨 schema 版本的升级链. 当前 currentSchemaVersion=1, 没有真正的迁移钩子要跑;
// 但框架已经搭好, 后续加 v2 / v3 时只需:
//   1. 实现 migrate_v1_to_v2(_:Data) -> Data 这种从老格式 JSON 读 + 改 + 输出新格式 JSON
//   2. 在 migrate(data:from:to:) 的 switch 里加一条
//
// 设计要点:
//   - 迁移在 Data (JSON) 层面做, 不引入 v1Config / v2Config 这种"每版一个 Codable struct"
//     的成本. 大多数升级是加字段或重命名, 直接在 JSON 字典上改即可.
//   - 链式升级: v0 -> v1 -> ... -> current, 一步一步. 不允许跨版本直接跳.
//   - 升级后 BundleIO.save 会以 currentSchemaVersion 重写 config.json, 以后再 load 不用再走.
//
// 详见 docs/VM_BUNDLE.md "schema 演进".

import Foundation
import HVMCore

public enum ConfigMigrator {
    /// 把 data (老 schema 的 config.json bytes) 升级到目标 schema, 返回新 JSON bytes.
    /// from > to / from == to 是调用方的责任 (BundleIO.load 已分流), 这里 from < to 才有意义.
    /// 升级链中任一步失败抛 .bundle(.invalidSchema).
    public static func migrate(data: Data, from: Int, to: Int) throws -> Data {
        // 当前 currentSchemaVersion=1, 还没有 v0 / v1->v2 这种迁移钩子, 命中即报错.
        // 加新版本时改成下面这种链式升级 (Swift 编译器能正确推断 var 必要性):
        //
        //   var current = data
        //   var version = from
        //   while version < to {
        //       let next = version + 1
        //       switch (version, next) {
        //       case (1, 2): current = try migrate_v1_to_v2(current)
        //       case (2, 3): current = try migrate_v2_to_v3(current)
        //       default: throw HVMError.bundle(.invalidSchema(version: version, expected: to))
        //       }
        //       version = next
        //   }
        //   return current
        if from < to {
            throw HVMError.bundle(.invalidSchema(version: from, expected: to))
        }
        return data
    }

    // MARK: - 各版本迁移 (按需实现)
    //
    // 模板:
    //
    // private static func migrate_v1_to_v2(_ data: Data) throws -> Data {
    //     guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    //         throw HVMError.bundle(.parseFailed(reason: "v1->v2: not a JSON dict", path: ""))
    //     }
    //     // 例: 把 "memoryMiB" 重命名为 "memoryBytes" 并 *1024*1024
    //     // if let m = dict["memoryMiB"] as? UInt64 {
    //     //     dict["memoryBytes"] = m * 1024 * 1024
    //     //     dict.removeValue(forKey: "memoryMiB")
    //     // }
    //     dict["schemaVersion"] = 2
    //     return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    // }
}
