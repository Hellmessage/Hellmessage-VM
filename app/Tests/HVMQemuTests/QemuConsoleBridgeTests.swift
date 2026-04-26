// HVMQemuTests/QemuConsoleBridgeTests.swift
// 用临时 unix socket pair 模拟 QEMU server 端, 验证 ringBuffer / read 增量语义.

import XCTest
@testable import HVMQemu
import Darwin

final class QemuConsoleBridgeTests: XCTestCase {

    // 启一个 listening socket 模拟 QEMU; 返 (path, listenFd).
    // accept handler 在 bg 线程跑, 收一个连接后把 dataToWrite 写出去
    private func startFakeServer(dataToWrite: Data) -> (path: String, listenFd: Int32) {
        let path = "/tmp/hvm-cb-test-\(UUID().uuidString.prefix(8)).sock"
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

        Thread.detachNewThread {
            let cf = accept(lf, nil, nil)
            if cf < 0 { return }
            // 写 dataToWrite 到 client
            _ = dataToWrite.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return send(cf, base, buf.count, 0)
            }
            // 等一会儿让 reader 消化, 再关掉 client end (触发 reader EOF)
            Thread.sleep(forTimeInterval: 0.3)
            shutdown(cf, SHUT_RDWR)
            Darwin.close(cf)
        }

        return (path, lf)
    }

    private func tempLogsDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-cb-logs-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - read 增量语义

    func testReadCapturesGuestOutput() throws {
        let payload = Data("Hello QEMU console\n".utf8)
        let (path, lf) = startFakeServer(dataToWrite: payload)
        defer {
            Darwin.close(lf)
            unlink(path)
        }
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }

        let bridge = QemuConsoleBridge(socketPath: path, logsDir: logsDir)
        try bridge.connect()
        // 给 reader 时间收完
        Thread.sleep(forTimeInterval: 0.5)

        let r = bridge.read(sinceBytes: 0)
        XCTAssertEqual(r.totalBytes, payload.count)
        XCTAssertEqual(r.returnedSinceBytes, 0)
        XCTAssertEqual(r.data, payload)
        bridge.close()
    }

    func testReadIncrementalSinceBytes() throws {
        let payload = Data("ABCDEFGHIJ".utf8)
        let (path, lf) = startFakeServer(dataToWrite: payload)
        defer { Darwin.close(lf); unlink(path) }
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }

        let bridge = QemuConsoleBridge(socketPath: path, logsDir: logsDir)
        try bridge.connect()
        Thread.sleep(forTimeInterval: 0.5)

        // 客户端从 sinceBytes=5 拉, 应只返回后 5 字节
        let r = bridge.read(sinceBytes: 5)
        XCTAssertEqual(r.totalBytes, 10)
        XCTAssertEqual(r.returnedSinceBytes, 5)
        XCTAssertEqual(r.data, Data("FGHIJ".utf8))
        bridge.close()
    }

    func testReadAtEndReturnsEmpty() throws {
        let payload = Data("xxx".utf8)
        let (path, lf) = startFakeServer(dataToWrite: payload)
        defer { Darwin.close(lf); unlink(path) }
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }

        let bridge = QemuConsoleBridge(socketPath: path, logsDir: logsDir)
        try bridge.connect()
        Thread.sleep(forTimeInterval: 0.5)

        // sinceBytes == totalBytes → empty data 但 totalBytes 仍报当前
        let r = bridge.read(sinceBytes: 3)
        XCTAssertEqual(r.totalBytes, 3)
        XCTAssertEqual(r.data.count, 0)
        bridge.close()
    }

    func testConnectFailsForNonexistentSocket() {
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }
        let bridge = QemuConsoleBridge(
            socketPath: "/tmp/hvm-no-such-\(UUID().uuidString.prefix(8)).sock",
            logsDir: logsDir
        )
        XCTAssertThrowsError(try bridge.connect()) { err in
            guard case QemuConsoleBridge.BridgeError.socketConnectFailed = err else {
                return XCTFail("期望 socketConnectFailed, 实际 \(err)")
            }
        }
    }

    func testCloseIsIdempotent() {
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }
        let bridge = QemuConsoleBridge(
            socketPath: "/tmp/hvm-no-such-\(UUID().uuidString.prefix(8)).sock",
            logsDir: logsDir
        )
        bridge.close()
        bridge.close()  // 第二次也安全
    }

    func testWriteBeforeConnectThrows() {
        let logsDir = tempLogsDir()
        defer { try? FileManager.default.removeItem(at: logsDir) }
        let bridge = QemuConsoleBridge(
            socketPath: "/tmp/hvm-no-such-\(UUID().uuidString.prefix(8)).sock",
            logsDir: logsDir
        )
        XCTAssertThrowsError(try bridge.write(Data("x".utf8))) { err in
            guard case QemuConsoleBridge.BridgeError.alreadyClosed = err else {
                return XCTFail("期望 alreadyClosed (fd<0), 实际 \(err)")
            }
        }
    }
}
