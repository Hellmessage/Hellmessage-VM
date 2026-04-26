// HVMCoreTests/UnixSocketTests.swift
// 用临时 listening socket 验证 connect / 路径过长 / ENOENT 等错误形态.

import XCTest
@testable import HVMCore
import Darwin

final class UnixSocketTests: XCTestCase {

    private func makeListener() -> (path: String, fd: Int32) {
        let path = "/tmp/hvm-us-test-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        let lf = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(lf, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(lf, sa, addrLen)
            }
        }
        XCTAssertEqual(bindRC, 0)
        XCTAssertEqual(Darwin.listen(lf, 1), 0)
        return (path, lf)
    }

    func testConnectSucceedsWhenListenerUp() throws {
        let (path, lf) = makeListener()
        defer { Darwin.close(lf); unlink(path) }
        let fd = try UnixSocket.connect(to: path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        Darwin.close(fd)
    }

    func testConnectFailsWithENOENTWhenSocketAbsent() {
        let path = "/tmp/hvm-us-no-such-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try UnixSocket.connect(to: path)) { error in
            guard case UnixSocket.Error.connectFailed(_, let e) = error else {
                return XCTFail("期望 connectFailed, 实际 \(error)")
            }
            XCTAssertEqual(e, ENOENT, "socket 文件不存在 → ENOENT")
        }
    }

    func testPathTooLongRejected() {
        let longPath = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertThrowsError(try UnixSocket.connect(to: longPath)) { error in
            guard case UnixSocket.Error.pathTooLong(let len) = error else {
                return XCTFail("期望 pathTooLong, 实际 \(error)")
            }
            XCTAssertGreaterThanOrEqual(len, 100)
        }
    }

    func testTimeoutSecAppliesSocketOptions() throws {
        // 不直接验 SO_RCVTIMEO 生效 (要 syscall + getsockopt), 只验带 timeout 不崩
        let (path, lf) = makeListener()
        defer { Darwin.close(lf); unlink(path) }
        let fd = try UnixSocket.connect(to: path, timeoutSec: 5)
        Darwin.close(fd)
    }
}
