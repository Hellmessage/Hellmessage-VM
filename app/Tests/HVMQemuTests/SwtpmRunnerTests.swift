// HVMQemuTests/SwtpmRunnerTests.swift
// 用 /bin/sh 模拟 swtpm 二进制测进程生命周期 + waitForSocketReady 行为.
// 不需要真 swtpm.

import XCTest
@testable import HVMQemu

final class SwtpmRunnerTests: XCTestCase {

    func testStartAndExitObserver() throws {
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "exit 0"],
            ctrlSocketPath: "/tmp/hvm-test-not-real.sock"
        )
        XCTAssertEqual(runner.state, .idle)

        let exp = expectation(description: "process exited")
        runner.addStateObserver { state in
            if case .exited = state { exp.fulfill() }
            if case .crashed = state { exp.fulfill() }
        }
        try runner.start()
        if case .running = runner.state {} else {
            XCTFail("start 后应 .running, 实际 \(runner.state)")
        }
        runner.waitUntilExit()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(runner.state, .exited(code: 0))
    }

    func testWaitForSocketReadyTimeoutWhenNoSocket() async throws {
        // sleep 进程不创建 socket; waitForSocketReady 应在超时后返 false
        let sock = "/tmp/hvm-test-no-such-\(UUID().uuidString.prefix(8)).sock"
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["10"],
            ctrlSocketPath: sock
        )
        try runner.start()
        let ready = await runner.waitForSocketReady(timeoutSec: 1)
        XCTAssertFalse(ready, "无 socket 文件时必须超时返 false")
        runner.forceKill()
        runner.waitUntilExit()
    }

    func testWaitForSocketReadyDetectsEarlyExit() async throws {
        // 进程瞬间退出, waitForSocketReady 应立即返 false (不等满 5s)
        let sock = "/tmp/hvm-test-early-\(UUID().uuidString.prefix(8)).sock"
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "exit 1"],
            ctrlSocketPath: sock
        )
        try runner.start()
        // 给点时间让 terminationHandler 跑
        let start = Date()
        let ready = await runner.waitForSocketReady(timeoutSec: 5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(ready)
        XCTAssertLessThan(elapsed, 2, "进程早退应立即返, 不该傻等满 5s; 实际 \(elapsed)s")
    }

    func testWaitForSocketReadySucceedsWhenSocketAppears() async throws {
        // 用 sh 在后台 touch socket 文件后 sleep, 模拟 swtpm bind 完成.
        let sock = "/tmp/hvm-test-fake-sock-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: sock) }
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "touch \(sock) && sleep 5"],
            ctrlSocketPath: sock
        )
        try runner.start()
        let ready = await runner.waitForSocketReady(timeoutSec: 3)
        XCTAssertTrue(ready, "socket 文件出现后必须返 true")
        runner.forceKill()
        runner.waitUntilExit()
    }

    func testForceKillSendsSigKill() throws {
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["60"],
            ctrlSocketPath: "/tmp/hvm-test-sk.sock"
        )
        let exp = expectation(description: "process ended")
        runner.addStateObserver { state in
            if case .exited = state { exp.fulfill() }
            if case .crashed = state { exp.fulfill() }
        }
        try runner.start()
        Thread.sleep(forTimeInterval: 0.1)
        runner.forceKill()
        runner.waitUntilExit()
        wait(for: [exp], timeout: 5)
        if case .crashed(let signal) = runner.state {
            XCTAssertEqual(signal, 9, "SIGKILL = 9")
        } else {
            XCTFail("期望 .crashed(9), 实际 \(runner.state)")
        }
    }

    func testTerminateSendsSigTerm() throws {
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["60"],
            ctrlSocketPath: "/tmp/hvm-test-st.sock"
        )
        let exp = expectation(description: "process ended")
        runner.addStateObserver { state in
            if case .crashed = state { exp.fulfill() }
            if case .exited = state { exp.fulfill() }
        }
        try runner.start()
        Thread.sleep(forTimeInterval: 0.1)
        runner.terminate()
        runner.waitUntilExit()
        wait(for: [exp], timeout: 5)
        if case .crashed(let signal) = runner.state {
            XCTAssertEqual(signal, 15, "SIGTERM = 15")
        } else {
            XCTFail("期望 .crashed(15), 实际 \(runner.state)")
        }
    }

    func testDoubleStartThrowsAlreadyStarted() throws {
        let runner = SwtpmRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["10"],
            ctrlSocketPath: "/tmp/hvm-test-ds.sock"
        )
        try runner.start()
        XCTAssertThrowsError(try runner.start()) { error in
            guard case SwtpmRunner.LaunchError.alreadyStarted = error else {
                return XCTFail("期望 alreadyStarted, 实际 \(error)")
            }
        }
        runner.forceKill()
        runner.waitUntilExit()
    }
}
