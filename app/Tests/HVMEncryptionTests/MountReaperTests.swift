// HVMEncryptionTests/MountReaperTests.swift
// 真跑 hdiutil 验证 MountReaper 对 stale sparsebundle 的清理.
//
// 关键验证 (T4 P0 must-pass 的本地版; 真机 panic 模拟留 PR-9):
//   - 模拟 host crash: attach sparsebundle 不 detach → reap 检测无 lock 持有 → force detach
//   - 活 VM 持锁: BundleLock 被测试进程持 → reap 跳过, 不动挂载
//   - 非 HVM 自家 sparsebundle: 路径不在 vmsRoot 前缀 → 不动

import XCTest
@testable import HVMEncryption
@testable import HVMBundle
@testable import HVMCore

final class MountReaperTests: XCTestCase {

    private var fakeVmsRoot: URL!
    /// 跟踪本测试 attach 出来的 mountpoint, tearDown 兜底 detach
    private var attachedMountpoints: [URL] = []

    override func setUpWithError() throws {
        // /tmp 短路径 (Unix socket sun_path 限 104, sparsebundle 内部 socket 路径预算)
        let uuid8 = String(UUID().uuidString.prefix(8))
        fakeVmsRoot = URL(fileURLWithPath: "/tmp/hvm-reap-\(uuid8)/VMs")
        try FileManager.default.createDirectory(at: fakeVmsRoot,
                                                 withIntermediateDirectories: true)
        attachedMountpoints = []
    }

    override func tearDownWithError() throws {
        // 兜底: 卸所有本测试的挂载 (force, 即使 reap 失败也要清干净)
        for mp in attachedMountpoints {
            try? SparsebundleTool.detach(mountpoint: mp, force: true)
        }
        if let r = fakeVmsRoot {
            try? FileManager.default.removeItem(at: r.deletingLastPathComponent())
        }
    }

    private let pw = "test-pass"

    /// 创建 + attach 一个 sparsebundle, 在 mountpoint 内建一个 fake .hvmz/ 子目录 + .lock
    /// 便于 BundleLock.isBusy 走文件存在性检查.
    /// 返回 (sparsebundleURL, mountpoint, hvmzURL)
    @discardableResult
    private func makeAttachedSparsebundle(name: String,
                                           inRoot root: URL? = nil) throws -> (URL, URL, URL) {
        let baseRoot = root ?? fakeVmsRoot!
        try FileManager.default.createDirectory(at: baseRoot,
                                                 withIntermediateDirectories: true)
        let sparsebundleURL = baseRoot.appendingPathComponent("\(name).hvmz.sparsebundle")
        try SparsebundleTool.create(at: sparsebundleURL,
                                     password: pw,
                                     options: .init(sizeBytes: 50 * 1024 * 1024,
                                                    volumeName: "HVM-test"))

        let uuid8 = String(UUID().uuidString.prefix(8))
        let mountpoint = URL(fileURLWithPath: "/tmp/hvm-reap-mp-\(uuid8)")
        try FileManager.default.createDirectory(at: mountpoint,
                                                 withIntermediateDirectories: true)
        _ = try SparsebundleTool.attach(at: sparsebundleURL,
                                         password: pw,
                                         mountpoint: mountpoint)
        attachedMountpoints.append(mountpoint)

        // 模拟 BundleIO.create 已建过 — 写一个空 .hvmz 目录 + .lock
        let hvmzURL = mountpoint.appendingPathComponent("\(name).hvmz", isDirectory: true)
        try FileManager.default.createDirectory(at: hvmzURL, withIntermediateDirectories: true)
        // 让 .lock 文件存在 (BundleLock.isBusy 路径需要 fileExists)
        let lockURL = BundleLayout.lockURL(hvmzURL)
        FileManager.default.createFile(atPath: lockURL.path, contents: nil)

        return (sparsebundleURL, mountpoint, hvmzURL)
    }

    // MARK: - 1. stale sparsebundle 被 reap

    func testReapsStaleSparsebundle() throws {
        let (sparsebundleURL, mountpoint, _) = try makeAttachedSparsebundle(name: "stale")

        // 此时 sparsebundle 已挂载, 没人持 .lock — reap 应识别 stale + force detach
        let stats = MountReaper.reapStaleMounts(hvmVmsRoot: fakeVmsRoot)

        let normalizedSparsebundle = sparsebundleURL.standardizedFileURL.path
        XCTAssertTrue(stats.detached.contains(normalizedSparsebundle),
                      "stale sparsebundle 应在 detached 列表中, 实=\(stats)")
        XCTAssertTrue(stats.failed.isEmpty, "不应有 failed: \(stats.failed)")

        // 验证: hdiutil info 已不再列此 sparsebundle
        let after = try SparsebundleTool.info()
        let stillAttached = after.contains { entry in
            URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path == normalizedSparsebundle
        }
        XCTAssertFalse(stillAttached, "detach 后 hdiutil info 不应再列")

        // attachedMountpoints 移除已 reap 的, 让 tearDown 不重复 detach
        attachedMountpoints.removeAll { $0.standardizedFileURL.path == mountpoint.standardizedFileURL.path }
    }

    // MARK: - 2. 活 VM 持 lock 跳过

    func testSkipsBusySparsebundle() throws {
        let (sparsebundleURL, _, hvmzURL) = try makeAttachedSparsebundle(name: "busy")

        // 持 BundleLock — 模拟活 VMHost
        let lock = try BundleLock(bundleURL: hvmzURL, mode: .runtime)
        defer { lock.release() }

        let stats = MountReaper.reapStaleMounts(hvmVmsRoot: fakeVmsRoot)
        let normalizedSparsebundle = sparsebundleURL.standardizedFileURL.path
        XCTAssertTrue(stats.skipped.contains(normalizedSparsebundle),
                      "活 VM 持 lock 应在 skipped, 实=\(stats)")
        XCTAssertFalse(stats.detached.contains(normalizedSparsebundle),
                       "活 VM 不应被 detach")

        // sparsebundle 仍挂着
        let after = try SparsebundleTool.info()
        let stillAttached = after.contains { entry in
            URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path == normalizedSparsebundle
        }
        XCTAssertTrue(stillAttached)
    }

    // MARK: - 3. 非 HVM 自家 sparsebundle 不动

    func testDoesNotReapNonHvmSparsebundle() throws {
        // 创建在 fakeVmsRoot **外** — 模拟用户自己的 sparsebundle / lima / colima 等
        let outsideRoot = URL(fileURLWithPath: "/tmp/hvm-reap-outside-\(String(UUID().uuidString.prefix(6)))")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }

        let (sparsebundleURL, mountpoint, _) = try makeAttachedSparsebundle(
            name: "outsider", inRoot: outsideRoot)

        // hvmVmsRoot 设为 fakeVmsRoot, 不包含 outsideRoot — reap 不应碰
        let stats = MountReaper.reapStaleMounts(hvmVmsRoot: fakeVmsRoot)
        let normalizedSparsebundle = sparsebundleURL.standardizedFileURL.path
        XCTAssertFalse(stats.detached.contains(normalizedSparsebundle),
                       "非 HVM 路径下的 sparsebundle 不应被 reap")
        XCTAssertFalse(stats.skipped.contains(normalizedSparsebundle))

        // 仍挂着, 等 tearDown 卸
        let after = try SparsebundleTool.info()
        let stillAttached = after.contains { entry in
            URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path == normalizedSparsebundle
        }
        XCTAssertTrue(stillAttached)

        // tearDown 会清; 但 mountpoint 仍在 attachedMountpoints
        _ = mountpoint
    }

    // MARK: - 4. 空状态 reap 不抛 + 返空 stats

    func testNoOpWhenNothingMounted() {
        let stats = MountReaper.reapStaleMounts(hvmVmsRoot: fakeVmsRoot)
        // 当前测试机器可能有别的非 HVM sparsebundle 挂着, 但 fakeVmsRoot 内没有
        XCTAssertTrue(stats.detached.isEmpty, "空 vmsRoot 不应 detach 任何, 实=\(stats.detached)")
    }
}
