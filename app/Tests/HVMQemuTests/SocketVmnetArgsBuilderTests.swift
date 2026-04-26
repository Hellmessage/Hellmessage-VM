// HVMQemuTests/SocketVmnetArgsBuilderTests.swift
// 纯函数: 验证 socket_vmnet argv 形态.

import XCTest
@testable import HVMQemu

final class SocketVmnetArgsBuilderTests: XCTestCase {

    func testSharedModeMinimalArgs() throws {
        let args = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
            mode: .shared,
            socketPath: "/tmp/run/abc.vmnet.sock"
        ))
        XCTAssertTrue(args.contains("--vmnet-mode=shared"))
        // socket path 是最后一个非选项参数
        XCTAssertEqual(args.last, "/tmp/run/abc.vmnet.sock")
        // shared 模式不应有 --vmnet-interface
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--vmnet-interface=") }))
    }

    func testBridgedRequiresInterface() {
        let inputs = SocketVmnetArgsBuilder.Inputs(
            mode: .bridged, socketPath: "/tmp/sock", bridgedInterface: nil
        )
        XCTAssertThrowsError(try SocketVmnetArgsBuilder.build(inputs)) { error in
            guard case SocketVmnetArgsBuilder.BuildError.bridgedRequiresInterface = error else {
                return XCTFail("期望 bridgedRequiresInterface, 实际 \(error)")
            }
        }
    }

    func testBridgedWithInterface() throws {
        let args = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
            mode: .bridged,
            socketPath: "/tmp/sock",
            bridgedInterface: "en0"
        ))
        XCTAssertTrue(args.contains("--vmnet-mode=bridged"))
        XCTAssertTrue(args.contains("--vmnet-interface=en0"))
        XCTAssertEqual(args.last, "/tmp/sock")
    }

    func testHostModeArgs() throws {
        let args = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
            mode: .host, socketPath: "/tmp/sock"
        ))
        XCTAssertTrue(args.contains("--vmnet-mode=host"))
    }

    func testPidFileOptional() throws {
        // 不传
        let bare = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
            mode: .shared, socketPath: "/tmp/sock"
        ))
        XCTAssertFalse(bare.contains(where: { $0.hasPrefix("--pidfile=") }))
        // 传了
        let withPid = try SocketVmnetArgsBuilder.build(SocketVmnetArgsBuilder.Inputs(
            mode: .shared, socketPath: "/tmp/sock",
            pidFile: URL(fileURLWithPath: "/tmp/vmnet.pid")
        ))
        XCTAssertTrue(withPid.contains("--pidfile=/tmp/vmnet.pid"))
    }
}
