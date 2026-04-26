// HVMInstall/VirtioWinCacheTests.swift
// 路径常量 + Progress 数学 + 错误类型. 不真发起 700MB 下载 (CI / 离线开发不友好);
// ensureCached 的真实下载由 GUI / hvm-cli 实战验证.

import XCTest
@testable import HVMInstall

final class VirtioWinCacheTests: XCTestCase {

    // MARK: - 静态常量

    func testDownloadURLIsFedoraStableChannel() {
        // 防止以后误改成 latest-virtio (会指向不稳定 nightly), 必须是 stable
        let s = VirtioWinCache.downloadURL.absoluteString
        XCTAssertTrue(s.contains("fedorapeople.org"))
        XCTAssertTrue(s.contains("stable-virtio"))
        XCTAssertTrue(s.hasSuffix("/virtio-win.iso"))
    }

    func testCachedISOURLEndsWithExpectedName() {
        let url = VirtioWinCache.cachedISOURL
        XCTAssertEqual(url.lastPathComponent, "virtio-win.iso")
        XCTAssertTrue(url.path.contains("HVM/cache/virtio-win"),
                      "缓存路径应在 HVM/cache/virtio-win/ 下, 实际: \(url.path)")
    }

    // MARK: - Progress 数学

    func testProgressFractionWithKnownTotal() throws {
        let p = VirtioWinCache.Progress(receivedBytes: 200_000_000, totalBytes: 800_000_000)
        XCTAssertEqual(try XCTUnwrap(p.fraction), 0.25, accuracy: 1e-9)
    }

    func testProgressFractionNilWhenTotalUnknown() {
        let p = VirtioWinCache.Progress(receivedBytes: 100, totalBytes: nil)
        XCTAssertNil(p.fraction)
    }

    func testProgressFractionNilWhenTotalZero() {
        // 防御: 服务端给 0 不应除零
        let p = VirtioWinCache.Progress(receivedBytes: 100, totalBytes: 0)
        XCTAssertNil(p.fraction)
    }

    func testProgressFractionAtCompletion() {
        let p = VirtioWinCache.Progress(receivedBytes: 700_000_000, totalBytes: 700_000_000)
        XCTAssertEqual(p.fraction!, 1.0, accuracy: 1e-9)
    }

    // MARK: - DownloadError Equatable

    func testDownloadErrorEquatable() {
        XCTAssertEqual(VirtioWinCache.DownloadError.httpStatus(404),
                       VirtioWinCache.DownloadError.httpStatus(404))
        XCTAssertNotEqual(VirtioWinCache.DownloadError.httpStatus(404),
                          VirtioWinCache.DownloadError.httpStatus(500))
        XCTAssertNotEqual(VirtioWinCache.DownloadError.httpStatus(404),
                          VirtioWinCache.DownloadError.cancelled)
    }
}
