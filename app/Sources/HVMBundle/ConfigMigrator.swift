// HVMBundle/ConfigMigrator.swift
// VMConfig 跨 schema 版本的升级链. 当前 currentSchemaVersion=2 (YAML).
//
// 历史:
//   v1 (JSON, config.json) — 已断兼容. BundleIO.load 检测到 config.json 直接报错,
//     不会进入此 migrator. 因此本文件不实现 v1→v2 hook.
//   v2 (YAML, config.yaml) — 当前. DiskSpec 加 format 字段.
//
// 设计要点 (未来 v3+ 加 hook 时):
//   1. 实现 migrate_v2_to_v3(_:Data) -> Data  从老 yaml 读 + 改 + 输出新 yaml
//   2. 在 migrate(data:from:to:) 的 switch 里加一条
//   3. 用 Yams 把 yaml 解析成 [String: Any] 字典, 改完再 dump 回 yaml string
//
// 链式升级: v_n → v_n+1 → ... → current, 一步一步. 不允许跨版本跳.
// 升级后 BundleIO.save 以 currentSchemaVersion 重写 yaml, 下次 load 直接走当前版本.
//
// **幂等约束 (硬规则)**:
//   每条 migrate_vN_to_vN+1 hook 必须满足:
//      migrate_vN_to_vN+1(migrate_vN_to_vN+1(x)) ≡ migrate_vN_to_vN+1(x)
//   即"对已经升过 N+1 的 yaml 跑一次 hook 应原样返回 (或抛错), 不能再次叠加变换".
//   反例: hook 把 memoryMiB 重命名为 memoryBytes 并 *1024*1024, 第二次跑会再 *1024*1024
//   爆炸. 对策: hook 内先 grep schemaVersion 字段, 已升级的提前 return.
//
//   ConfigMigratorTests.testIdempotency 在加 v3 hook 之前必须先扩 — 不允许 hook 落地
//   后再补测试 (用户已用过 v2 一段时间, 重跑迁移会覆盖用户后改的字段).

import Foundation
import HVMCore

public enum ConfigMigrator {
    /// 把 data (老 schema 的 config.yaml bytes) 升级到目标 schema, 返回新 yaml bytes.
    /// from > to / from == to 是调用方的责任 (BundleIO.load 已分流), 这里 from < to 才有意义.
    /// 升级链中任一步失败抛 .bundle(.invalidSchema).
    public static func migrate(data: Data, from: Int, to: Int) throws -> Data {
        // 当前 currentSchemaVersion=2, 还没有 v3 / v2→v3 hook. 任何 from<to 都报错.
        // 加新版本时改成下面这种链式升级:
        //
        //   var current = data
        //   var version = from
        //   while version < to {
        //       let next = version + 1
        //       switch (version, next) {
        //       case (2, 3): current = try migrate_v2_to_v3(current)
        //       case (3, 4): current = try migrate_v3_to_v4(current)
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
    // 模板 (yaml 数据流):
    //
    // import Yams
    // private static func migrate_v2_to_v3(_ data: Data) throws -> Data {
    //     guard let yamlStr = String(data: data, encoding: .utf8),
    //           var dict = try Yams.load(yaml: yamlStr) as? [String: Any] else {
    //         throw HVMError.bundle(.parseFailed(reason: "v2->v3: not a YAML dict", path: ""))
    //     }
    //     // 例: 把 "memoryMiB" 重命名为 "memoryBytes" 并 *1024*1024
    //     // if let m = dict["memoryMiB"] as? UInt64 {
    //     //     dict["memoryBytes"] = m * 1024 * 1024
    //     //     dict.removeValue(forKey: "memoryMiB")
    //     // }
    //     dict["schemaVersion"] = 3
    //     let out = try Yams.dump(object: dict, indent: 2, sortKeys: true)
    //     return Data(out.utf8)
    // }
}
