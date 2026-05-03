// BundleIO_LegacyJSONTests.swift
// 验证 v1 → v2 schema 断兼容路径: 用户从老版本带 config.json 上来时, BundleIO.load 必须
// 抛明确错误指引重新创建 VM (而不是部分 decode 出脏 VMConfig).

import XCTest
@testable import HVMBundle
@testable import HVMCore

final class BundleIO_LegacyJSONTests: XCTestCase {

    private var tempBundleURL: URL!

    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "hvm-bundleio-legacy-\(UUID().uuidString).hvmz"
        tempBundleURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: tempBundleURL,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempBundleURL)
        super.tearDown()
    }

    /// 仅有 config.json (v1 格式) 无 config.yaml → load 必须抛 bundle.parseFailed,
    /// 错误消息含 "config.json" 与 "v1" 关键词指引用户.
    func testLegacyJsonOnlyThrowsParseFailed() throws {
        let legacyURL = BundleLayout.legacyConfigURL(tempBundleURL)
        let dummy = #"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000000","displayName":"old"}"#
        try dummy.write(to: legacyURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BundleIO.load(from: tempBundleURL)) { error in
            guard let hvmErr = error as? HVMError,
                  case let .bundle(bundleErr) = hvmErr,
                  case let .parseFailed(reason, path) = bundleErr else {
                XCTFail("期望 .bundle(.parseFailed), 实际 \(error)")
                return
            }
            XCTAssertTrue(reason.contains("config.json"),
                          "错误消息应含 'config.json' 关键词, 实际: \(reason)")
            XCTAssertTrue(reason.contains("v1") || reason.contains("v2"),
                          "错误消息应提及 schema 版本, 实际: \(reason)")
            XCTAssertTrue(reason.contains("重新创建") || reason.contains("迁移"),
                          "错误消息应给可操作建议, 实际: \(reason)")
            XCTAssertEqual(path, legacyURL.path,
                           "path 应指向 config.json")
        }
    }

    /// 既无 config.json 也无 config.yaml → 抛 bundle.notFound (不是 parseFailed).
    func testEmptyBundleThrowsNotFound() throws {
        XCTAssertThrowsError(try BundleIO.load(from: tempBundleURL)) { error in
            guard let hvmErr = error as? HVMError,
                  case let .bundle(bundleErr) = hvmErr,
                  case .notFound = bundleErr else {
                XCTFail("期望 .bundle(.notFound), 实际 \(error)")
                return
            }
        }
    }

    /// 错误码渲染到 userFacing.code 时应是 bundle.parse_failed (非 unknown).
    /// 这是 docs/CLI.md 退出码映射依赖的关键.
    func testLegacyJsonUserFacingCode() throws {
        let legacyURL = BundleLayout.legacyConfigURL(tempBundleURL)
        try "{\"schemaVersion\":1}".write(to: legacyURL, atomically: true, encoding: .utf8)

        do {
            _ = try BundleIO.load(from: tempBundleURL)
            XCTFail("应抛错")
        } catch let e as HVMError {
            let uf = e.userFacing
            XCTAssertTrue(uf.code.hasPrefix("bundle."),
                          "错误码应在 bundle.* 命名空间, 实际: \(uf.code)")
        } catch {
            XCTFail("期望 HVMError, 实际 \(error)")
        }
    }
}
