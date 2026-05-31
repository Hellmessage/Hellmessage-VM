// HVMBundle/ConfigMigrator.swift
// VMConfig 跨 schema 版本的链式升级 (v_n → v_n+1 → ... → current, 不跨版本跳).
// 升级后 BundleIO.save 以 currentSchemaVersion 重写 yaml.
//   v1 (JSON)  — 已断兼容
//   v2 (YAML)  — 加 DiskSpec.format
//   v3 (YAML)  — 加顶层 encryption: EncryptionSpec?
//
// 幂等硬约束: 每条 migrate hook 对已升过的 yaml 重跑必须原样返回, 不能叠加变换
// (内部先查 schemaVersion 提前 return). v2→v3 是 additive 天然幂等.

import Foundation
import HVMCore
import Yams

public enum ConfigMigrator {
    /// 把 data (老 schema 的 config.yaml bytes) 升级到目标 schema, 返回新 yaml bytes.
    /// from > to / from == to 是调用方的责任 (BundleIO.load 已分流), 这里 from < to 才有意义.
    /// 升级链中任一步失败抛 .bundle(.invalidSchema).
    public static func migrate(data: Data, from: Int, to: Int) throws -> Data {
        if from > to {
            throw HVMError.bundle(.invalidSchema(version: from, expected: to))
        }
        if from == to {
            return data
        }
        var current = data
        var version = from
        while version < to {
            let next = version + 1
            switch (version, next) {
            case (2, 3):
                current = try migrate_v2_to_v3(current)
            default:
                throw HVMError.bundle(.invalidSchema(version: version, expected: to))
            }
            version = next
        }
        return current
    }

    // MARK: - v2 → v3 (加顶层 encryption 字段)

    /// v2 → v3: yaml 顶层加 `encryption: { enabled: false }` (兜底), schemaVersion 改 3.
    /// 已是 v3 的 yaml 直接返原 data (幂等防御, 不重复加).
    private static func migrate_v2_to_v3(_ data: Data) throws -> Data {
        guard let yamlStr = String(data: data, encoding: .utf8) else {
            throw HVMError.bundle(.parseFailed(reason: "v2->v3: 非 utf8 yaml", path: ""))
        }
        let parsed: Any?
        do {
            parsed = try Yams.load(yaml: yamlStr)
        } catch {
            throw HVMError.bundle(.parseFailed(reason: "v2->v3: yaml parse: \(error)", path: ""))
        }
        guard var dict = parsed as? [String: Any] else {
            throw HVMError.bundle(.parseFailed(reason: "v2->v3: yaml 顶层非 dict", path: ""))
        }

        // 幂等: 已经是 v3 noop
        if let v = dict["schemaVersion"] as? Int, v >= 3 {
            return data
        }

        // additive: 仅在 encryption 缺省时加
        if dict["encryption"] == nil {
            dict["encryption"] = ["enabled": false]
        }
        dict["schemaVersion"] = 3

        let out = try Yams.dump(object: dict, indent: 2, allowUnicode: true, sortKeys: true)
        return Data(out.utf8)
    }
}
