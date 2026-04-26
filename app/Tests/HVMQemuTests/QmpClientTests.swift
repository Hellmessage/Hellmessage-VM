// HVMQemuTests/QmpClientTests.swift
// 用 FakeQmpServer 驱动会话, 验证 QmpClient 的握手 / 命令-响应配对 / 事件流 / 错误.

import XCTest
@testable import HVMQemu

final class QmpClientTests: XCTestCase {

    // MARK: - 握手

    func testConnectPerformsGreetingAndCapabilitiesHandshake() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        try server.start { conn in
            // 1. greeting
            try? conn.sendJSON([
                "QMP": [
                    "version": ["qemu": ["major": 10, "minor": 2, "micro": 0], "package": ""],
                    "capabilities": []
                ]
            ])
            // 2. 期待 qmp_capabilities
            let cmd = try? conn.recvJSONLine()
            XCTAssertEqual(cmd?["execute"] as? String, "qmp_capabilities")
            let id = cmd?["id"] as? String ?? "?"
            try? conn.sendJSON(["return": [String: Any](), "id": id])
            // 之后保持连接
            Thread.sleep(forTimeInterval: 0.5)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()
        client.close()
    }

    // MARK: - 类型化命令

    func testQueryStatusParsesRunningState() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        try server.start { conn in
            try? conn.sendJSON(["QMP": ["version": [String: Any](), "capabilities": []]])
            let caps = try? conn.recvJSONLine()
            try? conn.sendJSON(["return": [String: Any](), "id": caps?["id"] as? String ?? ""])

            // query-status
            let q = try? conn.recvJSONLine()
            XCTAssertEqual(q?["execute"] as? String, "query-status")
            try? conn.sendJSON([
                "return": [
                    "status": "running",
                    "running": true,
                    "singlestep": false
                ],
                "id": q?["id"] as? String ?? ""
            ])
            Thread.sleep(forTimeInterval: 0.3)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()
        let status = try await client.queryStatus()
        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.singlestep, false)
        client.close()
    }

    func testSystemPowerdownSendsCorrectCommand() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        let observed = ObservedCommand()
        try server.start { conn in
            try? conn.sendJSON(["QMP": ["version": [String: Any](), "capabilities": []]])
            let caps = try? conn.recvJSONLine()
            try? conn.sendJSON(["return": [String: Any](), "id": caps?["id"] as? String ?? ""])

            let cmd = try? conn.recvJSONLine()
            observed.set(cmd?["execute"] as? String)
            try? conn.sendJSON(["return": [String: Any](), "id": cmd?["id"] as? String ?? ""])
            Thread.sleep(forTimeInterval: 0.3)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()
        try await client.systemPowerdown()
        client.close()

        XCTAssertEqual(observed.value, "system_powerdown")
    }

    // MARK: - QEMU error 路径

    func testCommandErrorPropagatesAsQmpError() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        try server.start { conn in
            try? conn.sendJSON(["QMP": ["version": [String: Any](), "capabilities": []]])
            let caps = try? conn.recvJSONLine()
            try? conn.sendJSON(["return": [String: Any](), "id": caps?["id"] as? String ?? ""])

            let cmd = try? conn.recvJSONLine()
            try? conn.sendJSON([
                "error": ["class": "GenericError", "desc": "command not supported"],
                "id": cmd?["id"] as? String ?? ""
            ])
            Thread.sleep(forTimeInterval: 0.3)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()
        do {
            _ = try await client.queryStatus()
            XCTFail("expected QmpError.qemu")
        } catch QmpError.qemu(let cls, let desc) {
            XCTAssertEqual(cls, "GenericError")
            XCTAssertEqual(desc, "command not supported")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        client.close()
    }

    // MARK: - 异步事件流

    func testEventsArriveOnAsyncStream() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        try server.start { conn in
            try? conn.sendJSON(["QMP": ["version": [String: Any](), "capabilities": []]])
            let caps = try? conn.recvJSONLine()
            try? conn.sendJSON(["return": [String: Any](), "id": caps?["id"] as? String ?? ""])

            // 推一个 SHUTDOWN 事件
            Thread.sleep(forTimeInterval: 0.05)
            try? conn.sendJSON([
                "event": "SHUTDOWN",
                "timestamp": ["seconds": 1700000000, "microseconds": 0],
                "data": ["guest": true, "reason": "guest-shutdown"]
            ])
            Thread.sleep(forTimeInterval: 0.5)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()

        var first: QmpEvent?
        for await e in client.events {
            first = e
            break
        }
        client.close()

        XCTAssertEqual(first?.name, "SHUTDOWN")
        XCTAssertGreaterThan(first?.dataJSON.count ?? 0, 0)
    }

    // MARK: - close 行为

    func testCloseCancelsPendingCommands() async throws {
        let server = FakeQmpServer()
        defer { server.stop() }

        try server.start { conn in
            try? conn.sendJSON(["QMP": ["version": [String: Any](), "capabilities": []]])
            let caps = try? conn.recvJSONLine()
            try? conn.sendJSON(["return": [String: Any](), "id": caps?["id"] as? String ?? ""])

            // 收到命令但故意不响应
            _ = try? conn.recvJSONLine()
            Thread.sleep(forTimeInterval: 1.0)
        }

        let client = QmpClient(socketPath: server.path)
        try await client.connect()

        let task = Task {
            do {
                _ = try await client.queryStatus()
                return "no-throw"
            } catch QmpError.closed {
                return "closed"
            } catch {
                return "other: \(error)"
            }
        }
        // 给点时间让命令真正发出
        try await Task.sleep(nanoseconds: 100_000_000)
        client.close()
        let result = await task.value
        XCTAssertEqual(result, "closed")
    }
}

// MARK: - 跨线程小盒子

private final class ObservedCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    func set(_ v: String?) { lock.lock(); _value = v; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
}
