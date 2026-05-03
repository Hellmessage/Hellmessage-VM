// HVMBundleTests/ConfigMigratorTests.swift
// schema 迁移框架测试. 当前 currentSchemaVersion=3.
// 测 v2→v3 (加 encryption 字段) 的正确性 + 幂等.

import XCTest
import Yams
@testable import HVMBundle

final class ConfigMigratorTests: XCTestCase {

    // MARK: - 框架

    /// from == to 直接返原 data
    func testMigrateNoopWhenSameVersion() throws {
        let data = #"{"schemaVersion":3,"foo":"bar"}"#.data(using: .utf8)!
        let out = try ConfigMigrator.migrate(data: data, from: 3, to: 3)
        XCTAssertEqual(out, data)
    }

    /// from > to 是非法 (调用方逻辑错), 抛 .invalidSchema
    func testMigrateRejectsBackwards() throws {
        let data = Data()
        XCTAssertThrowsError(try ConfigMigrator.migrate(data: data, from: 3, to: 2))
    }

    /// 不存在的版本步进抛 .invalidSchema (e.g. 0 → 1 没 hook)
    func testMigrateUnknownVersionThrows() {
        let data = Data()
        XCTAssertThrowsError(try ConfigMigrator.migrate(data: data, from: 0, to: 1))
    }

    // MARK: - v2 → v3

    private func sampleV2Yaml() -> Data {
        let s = """
        schemaVersion: 2
        id: 11111111-2222-3333-4444-555555555555
        createdAt: 2026-01-01T00:00:00Z
        displayName: Foo
        guestOS: linux
        engine: vz
        cpuCount: 2
        memoryMiB: 2048
        disks:
        - format: raw
          path: disks/os.img
          readOnly: false
          role: main
          sizeGiB: 1
        networks: []
        bootFromDiskOnly: false
        windowsDriversInstalled: false
        clipboardSharingEnabled: true
        macStyleShortcuts: true
        linux:
          rosettaShare: false
        """
        return Data(s.utf8)
    }

    func testV2ToV3AddsEncryptionAndBumpsVersion() throws {
        let v2 = sampleV2Yaml()
        let v3 = try ConfigMigrator.migrate(data: v2, from: 2, to: 3)

        let yaml = String(data: v3, encoding: .utf8)!
        guard let dict = try Yams.load(yaml: yaml) as? [String: Any] else {
            XCTFail("v3 yaml 顶层应是 dict")
            return
        }
        XCTAssertEqual(dict["schemaVersion"] as? Int, 3)
        guard let enc = dict["encryption"] as? [String: Any] else {
            XCTFail("v3 应有 encryption 字段")
            return
        }
        XCTAssertEqual(enc["enabled"] as? Bool, false,
                       "v2→v3 兜底 encryption.enabled=false (老 VM 默认明文)")
    }

    /// 幂等: 对已是 v3 的 yaml 跑 migrate 应原样返回 (不重复加字段)
    func testV2ToV3Idempotent() throws {
        let v2 = sampleV2Yaml()
        let v3 = try ConfigMigrator.migrate(data: v2, from: 2, to: 3)
        // 假装老程序又把它当 v2 升一次 (理论上 BundleIO 不会, 但防御层)
        let v3Again = try ConfigMigrator.migrate(data: v3, from: 2, to: 3)

        let dict1 = try Yams.load(yaml: String(data: v3, encoding: .utf8)!) as! [String: Any]
        let dict2 = try Yams.load(yaml: String(data: v3Again, encoding: .utf8)!) as! [String: Any]

        // 重要: encryption 字段不能被覆盖成 default (encryption.enabled 维持原值)
        let enc1 = dict1["encryption"] as! [String: Any]
        let enc2 = dict2["encryption"] as! [String: Any]
        XCTAssertEqual(enc1["enabled"] as? Bool, enc2["enabled"] as? Bool,
                       "幂等: 第二次 migrate 不应重写 encryption 字段")
    }

    /// 用户在 v2 yaml 手工加了 encryption 字段 (假设 enabled=true), v2→v3 应保留, 不被覆盖
    func testV2ToV3PreservesUserAddedEncryption() throws {
        let s = """
        schemaVersion: 2
        id: 11111111-2222-3333-4444-555555555555
        createdAt: 2026-01-01T00:00:00Z
        displayName: Foo
        guestOS: linux
        engine: vz
        cpuCount: 2
        memoryMiB: 2048
        disks:
        - format: raw
          path: disks/os.img
          readOnly: false
          role: main
          sizeGiB: 1
        networks: []
        bootFromDiskOnly: false
        windowsDriversInstalled: false
        clipboardSharingEnabled: true
        macStyleShortcuts: true
        encryption:
          enabled: true
          scheme: vz-sparsebundle
        linux:
          rosettaShare: false
        """
        let v2 = Data(s.utf8)
        let v3 = try ConfigMigrator.migrate(data: v2, from: 2, to: 3)
        let dict = try Yams.load(yaml: String(data: v3, encoding: .utf8)!) as! [String: Any]
        let enc = dict["encryption"] as! [String: Any]
        XCTAssertEqual(enc["enabled"] as? Bool, true, "用户已设的 enabled=true 必须保留")
        XCTAssertEqual(enc["scheme"] as? String, "vz-sparsebundle", "用户已设的 scheme 必须保留")
    }
}
