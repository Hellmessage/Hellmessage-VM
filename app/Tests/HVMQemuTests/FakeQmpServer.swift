// HVMQemuTests/FakeQmpServer.swift
// 单连接 fake QMP 服务端, 供 QmpClient 测试驱动会话.
// 协议: JSON over unix socket, \r\n 分隔. 与真实 QEMU QMP 一致.

import Foundation
import Darwin

final class FakeQmpServer: @unchecked Sendable {
    let path: String
    private var listenFd: Int32 = -1
    private let lock = NSLock()
    private var serverThread: Thread?
    private(set) var clientFd: Int32 = -1
    private var connectedSem = DispatchSemaphore(value: 0)

    init() {
        let id = UUID().uuidString.prefix(8)
        // /tmp 比 NSTemporaryDirectory() 路径短, 避免 sockaddr_un.sun_path 104 字节限制
        self.path = "/tmp/hvm-qmp-test-\(id).sock"
    }

    deinit { stop() }

    /// 启动监听, 在后台线程 accept 一个连接, 然后调用 handler 处理会话.
    /// handler 在后台线程上执行; 退出后服务端自动关闭.
    func start(handler: @escaping (FakeConnection) -> Void) throws {
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw FakeError.socket("socket() failed errno=\(errno)")
        }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw FakeError.socket("path 太长")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFd, sa, addrLen)
            }
        }
        guard bindRC == 0 else {
            let saved = errno
            Darwin.close(listenFd); listenFd = -1
            throw FakeError.socket("bind \(path) errno=\(saved)")
        }
        guard listen(listenFd, 1) == 0 else {
            let saved = errno
            Darwin.close(listenFd); listenFd = -1
            throw FakeError.socket("listen errno=\(saved)")
        }

        let lf = listenFd
        let t = Thread { [weak self] in
            let cfd = accept(lf, nil, nil)
            guard let self else {
                if cfd >= 0 { Darwin.close(cfd) }
                return
            }
            self.lock.lock()
            self.clientFd = cfd
            self.lock.unlock()
            self.connectedSem.signal()
            if cfd >= 0 {
                let conn = FakeConnection(fd: cfd)
                handler(conn)
            }
        }
        t.start()
        serverThread = t
    }

    /// 等到一个客户端 accept (用于测试同步)
    @discardableResult
    func waitForConnection(timeoutSec: Int = 5) -> Bool {
        connectedSem.wait(timeout: .now() + .seconds(timeoutSec)) == .success
    }

    func stop() {
        lock.lock()
        let cf = clientFd; clientFd = -1
        let lf = listenFd; listenFd = -1
        lock.unlock()
        if cf >= 0 { Darwin.close(cf) }
        if lf >= 0 { Darwin.close(lf) }
        unlink(path)
    }

    enum FakeError: Error {
        case socket(String)
    }
}

final class FakeConnection: @unchecked Sendable {
    let fd: Int32

    init(fd: Int32) { self.fd = fd }

    /// 向客户端发一条 JSON 行 (自动加 \r\n)
    func sendJSON(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0D); data.append(0x0A)
        let n = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return send(fd, base, buf.count, 0)
        }
        guard n == data.count else {
            throw FakeQmpServer.FakeError.socket("send short \(n)/\(data.count) errno=\(errno)")
        }
    }

    /// 同步从客户端读一行 JSON (按 \r\n 切)
    func recvJSONLine() throws -> [String: Any] {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = recv(fd, &byte, 1, 0)
            if n <= 0 {
                throw FakeQmpServer.FakeError.socket("recv eof n=\(n) errno=\(errno)")
            }
            buffer.append(byte)
            if buffer.count >= 2,
               buffer[buffer.count - 2] == 0x0D,
               buffer[buffer.count - 1] == 0x0A {
                let line = buffer.subdata(in: 0..<(buffer.count - 2))
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw FakeQmpServer.FakeError.socket("not a JSON dict: \(String(data: line, encoding: .utf8) ?? "?")")
                }
                return obj
            }
        }
    }

    func close() {
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }
}
