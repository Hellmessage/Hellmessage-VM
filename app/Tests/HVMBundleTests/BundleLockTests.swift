// BundleLockTests.swift
// 验证 BundleLock 核心契约:
//   - 同进程内并发调 release() 不 double-close (P0 #5 NSLock 修补)
//   - LOCK_EX | LOCK_NB 阻止同进程二次抢锁 (CLAUDE.md "一 .hvmz 单进程" 同进程语义)
//
// 跨进程互斥(两个 Process 抢同一 lock 文件)只能在集成测验, 不在单元测层覆盖.

import XCTest
@testable import HVMBundle
@testable import HVMCore

final class BundleLockTests: XCTestCase {

    private var bundleURL: URL!

    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "hvm-bundlelock-test-\(UUID().uuidString).hvmz"
        bundleURL = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    // MARK: - 线程安全

    /// release() 是 idempotent 的, 100 路并发调用应不 crash + 不 double-close fd.
    /// 老逻辑非原子 Bool guard 在并发时两路都通过 -> close(fd) 两次, kernel 行为不保证幂等.
    func testConcurrentReleaseIsSafe() async throws {
        let lock = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { lock.release() }
            }
        }
        // 没 crash 即过. TSan 跑应无 data race 报告.
    }

    /// release() 之后的 release() 仍然 idempotent (单线程语义).
    func testRepeatedReleaseSingleThread() throws {
        let lock = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        lock.release()
        lock.release()
        lock.release()
    }

    // MARK: - 互斥

    /// 同进程内: 第一把锁还活着时, 第二把抢同一 bundle 应抛 .busy.
    func testSameProcessSecondLockBusy() throws {
        let first = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        XCTAssertThrowsError(try BundleLock(bundleURL: bundleURL, mode: .runtime)) { err in
            guard case let HVMError.bundle(bundleErr) = err,
                  case let .busy(pid, _) = bundleErr else {
                XCTFail("期望 .bundle(.busy), 实际 \(err)")
                return
            }
            // pid 应是当前进程 (持有者写入 holder info)
            XCTAssertEqual(pid, getpid(), "持有者 pid 应是当前进程")
        }
        first.release()
    }

    /// 第一把释放后, 第二把应能成功抢到.
    func testReleaseAllowsReacquire() throws {
        let first = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        first.release()
        let second = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        second.release()
    }

    // MARK: - holder 信息

    /// 抢锁时写入 HolderInfo, inspect() 能读出 pid + mode.
    func testInspectReadsHolderInfo() throws {
        let lock = try BundleLock(bundleURL: bundleURL, mode: .edit, socketPath: "/tmp/test.sock")
        defer { lock.release() }

        let holder = BundleLock.inspect(bundleURL: bundleURL)
        XCTAssertNotNil(holder)
        XCTAssertEqual(holder?.pid, getpid())
        XCTAssertEqual(holder?.mode, "edit")
        XCTAssertEqual(holder?.socketPath, "/tmp/test.sock")
    }

    /// isBusy() 是无副作用探测, 探测不应阻止后续抢锁.
    func testIsBusyDoesNotInterfere() throws {
        XCTAssertFalse(BundleLock.isBusy(bundleURL: bundleURL),
                       "无人持有时 isBusy 应是 false")
        let lock = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        XCTAssertTrue(BundleLock.isBusy(bundleURL: bundleURL),
                      "持有时 isBusy 应是 true")
        lock.release()
        XCTAssertFalse(BundleLock.isBusy(bundleURL: bundleURL),
                       "释放后 isBusy 应回 false")
        // 探测后仍能再抢
        let again = try BundleLock(bundleURL: bundleURL, mode: .runtime)
        again.release()
    }
}
