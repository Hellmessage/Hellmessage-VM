// HVMQemuTests/SwtpmArgsBuilderTests.swift
// 纯函数测试 SwtpmArgsBuilder.build 的 argv 形态.

import XCTest
@testable import HVMQemu

final class SwtpmArgsBuilderTests: XCTestCase {

    func testBuildHasTPM2AndCtrlSocket() {
        let args = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: URL(fileURLWithPath: "/tmp/tpm-state", isDirectory: true),
            ctrlSocketPath: "/tmp/run/abc.swtpm.sock"
        ))
        XCTAssertEqual(args.first, "socket")
        XCTAssertTrue(args.contains("--tpm2"))
        // --tpmstate dir=...
        let stateIdx = args.firstIndex(of: "--tpmstate") ?? -1
        XCTAssertGreaterThanOrEqual(stateIdx, 0)
        XCTAssertEqual(args[stateIdx + 1], "dir=/tmp/tpm-state")
        // --ctrl type=unixio,path=...
        let ctrlIdx = args.firstIndex(of: "--ctrl") ?? -1
        XCTAssertGreaterThanOrEqual(ctrlIdx, 0)
        XCTAssertEqual(args[ctrlIdx + 1], "type=unixio,path=/tmp/run/abc.swtpm.sock")
    }

    func testTerminateFlagPresent() {
        let args = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: URL(fileURLWithPath: "/tmp/tpm"),
            ctrlSocketPath: "/tmp/sock"
        ))
        XCTAssertTrue(args.contains("--terminate"),
                      "--terminate 必须在场: QEMU 断开后 swtpm 自动退避免泄漏")
    }

    func testLogAndPidOptional() {
        // 不传 logFile / pidFile → argv 不应含 --log / --pid
        let argsBare = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: URL(fileURLWithPath: "/tmp/tpm"),
            ctrlSocketPath: "/tmp/sock"
        ))
        XCTAssertFalse(argsBare.contains("--log"))
        XCTAssertFalse(argsBare.contains("--pid"))

        // 传了 → 应有
        let argsFull = SwtpmArgsBuilder.build(SwtpmArgsBuilder.Inputs(
            stateDir: URL(fileURLWithPath: "/tmp/tpm"),
            ctrlSocketPath: "/tmp/sock",
            logFile: URL(fileURLWithPath: "/tmp/swtpm.log"),
            pidFile: URL(fileURLWithPath: "/tmp/swtpm.pid"),
            logLevel: 5
        ))
        XCTAssertTrue(argsFull.contains("--log"))
        XCTAssertTrue(argsFull.contains("--pid"))
        let logIdx = argsFull.firstIndex(of: "--log")!
        XCTAssertEqual(argsFull[logIdx + 1], "level=5,file=/tmp/swtpm.log")
        let pidIdx = argsFull.firstIndex(of: "--pid")!
        XCTAssertEqual(argsFull[pidIdx + 1], "file=/tmp/swtpm.pid")
    }
}
