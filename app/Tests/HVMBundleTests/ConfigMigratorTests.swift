// HVMBundleTests/ConfigMigratorTests.swift
// schema 迁移框架的占位测试 (current=1 时只验 noop / 越界报错行为).
// 加 v2 时在这里补 v1->v2 的迁移正确性测试.

import XCTest
@testable import HVMBundle

final class ConfigMigratorTests: XCTestCase {

    /// from == to 直接返原 data
    func testMigrateNoopWhenSameVersion() throws {
        let data = #"{"schemaVersion":1,"foo":"bar"}"#.data(using: .utf8)!
        let out = try ConfigMigrator.migrate(data: data, from: 1, to: 1)
        XCTAssertEqual(out, data)
    }

    /// 当前没 v0 -> v1 钩子, 让升级请求落 default 报错
    func testMigrateUnknownVersionThrows() {
        let data = Data()
        XCTAssertThrowsError(try ConfigMigrator.migrate(data: data, from: 0, to: 1))
    }
}
