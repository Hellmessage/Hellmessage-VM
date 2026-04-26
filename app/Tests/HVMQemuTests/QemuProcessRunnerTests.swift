// HVMQemuTests/QemuProcessRunnerTests.swift
// 用 /bin/echo 与 /bin/sleep 当 fake binary 测进程生命周期, 不需要真 QEMU.

import XCTest
@testable import HVMQemu

final class QemuProcessRunnerTests: XCTestCase {

    func testEchoRunsAndExitsCleanly() throws {
        let runner = QemuProcessRunner(
            binary: URL(fileURLWithPath: "/bin/echo"),
            args: ["hello"]
        )
        XCTAssertEqual(runner.state, .idle)

        let exitedExp = expectation(description: "process exited")
        runner.addStateObserver { state in
            if case .exited = state { exitedExp.fulfill() }
            if case .crashed = state { exitedExp.fulfill() }
        }

        try runner.start()
        // 启动后 state 立即是 running
        if case .running = runner.state {} else {
            XCTFail("start 后 state 应为 .running, 实际 \(runner.state)")
        }

        runner.waitUntilExit()
        wait(for: [exitedExp], timeout: 5)

        XCTAssertEqual(runner.state, .exited(code: 0))
    }

    func testSleepCanBeTerminated() throws {
        let runner = QemuProcessRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["60"]
        )
        let endedExp = expectation(description: "process ended")
        runner.addStateObserver { state in
            if case .exited = state { endedExp.fulfill() }
            if case .crashed = state { endedExp.fulfill() }
        }

        try runner.start()
        // 给一点时间让 process 真正起来再 terminate
        Thread.sleep(forTimeInterval: 0.1)
        runner.terminate()
        runner.waitUntilExit()
        wait(for: [endedExp], timeout: 5)

        // SIGTERM 让 sleep 退出, terminationReason 是 .uncaughtSignal → .crashed(15)
        if case .crashed(let signal) = runner.state {
            XCTAssertEqual(signal, 15, "SIGTERM = 15")
        } else {
            XCTFail("期望 .crashed(15), 实际 \(runner.state)")
        }
    }

    func testForceKillSendsSigKill() throws {
        let runner = QemuProcessRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["60"]
        )
        let endedExp = expectation(description: "process ended")
        runner.addStateObserver { state in
            if case .exited = state { endedExp.fulfill() }
            if case .crashed = state { endedExp.fulfill() }
        }

        try runner.start()
        Thread.sleep(forTimeInterval: 0.1)
        runner.forceKill()
        runner.waitUntilExit()
        wait(for: [endedExp], timeout: 5)

        if case .crashed(let signal) = runner.state {
            XCTAssertEqual(signal, 9, "SIGKILL = 9")
        } else {
            XCTFail("期望 .crashed(9), 实际 \(runner.state)")
        }
    }

    func testDoubleStartThrows() throws {
        let runner = QemuProcessRunner(
            binary: URL(fileURLWithPath: "/bin/sleep"),
            args: ["10"]
        )
        try runner.start()
        XCTAssertThrowsError(try runner.start()) { error in
            guard case QemuProcessRunner.LaunchError.alreadyStarted = error else {
                return XCTFail("期望 alreadyStarted, 实际 \(error)")
            }
        }
        runner.forceKill()
        runner.waitUntilExit()
    }

    func testStderrCapturedToFile() throws {
        // /usr/bin/printf "err\n" 1>&2 不能直接走 Process.arguments, 改用 sh -c
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-runner-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }

        let runner = QemuProcessRunner(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "echo HELLO_STDERR 1>&2"],
            stderrLog: logURL
        )
        let endedExp = expectation(description: "process ended")
        runner.addStateObserver { state in
            if case .exited = state { endedExp.fulfill() }
        }
        try runner.start()
        runner.waitUntilExit()
        wait(for: [endedExp], timeout: 5)

        // 给 readabilityHandler 一点时间 flush
        Thread.sleep(forTimeInterval: 0.2)
        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("HELLO_STDERR"),
                      "stderr 应该被 tee 到 \(logURL.path), 实际内容: \(content)")
    }
}
