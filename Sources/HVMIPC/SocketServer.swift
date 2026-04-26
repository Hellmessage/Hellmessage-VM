// HVMIPC/SocketServer.swift
// Unix domain socket 服务端. 每个连接串行处理单请求/单响应 (M1)
// 运行于 HVMHost 进程内

import Foundation
import Darwin
import HVMCore

public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) -> IPCResponse

    private let path: String
    private var listenFd: Int32 = -1
    private var acceptThread: Thread?
    private var handler: Handler?
    private var stopped = false

    private static let log = HVMLog.logger("ipc.server")

    public init(socketPath: URL) {
        self.path = socketPath.path
    }

    /// 绑定并开始 accept. handler 将在独立线程上被调用, 必须线程安全
    public func start(handler: @escaping Handler) throws {
        // 预清理旧 socket (上次崩溃留下)
        unlink(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HVMError.ipc(.serverBindFailed(path: path, errno: errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw HVMError.ipc(.serverBindFailed(path: path, errno: ENAMETOOLONG))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrLen)
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(fd)
            throw HVMError.ipc(.serverBindFailed(path: path, errno: saved))
        }
        // socket 文件权限 0600 (仅 owner 可访问)
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let saved = errno
            close(fd)
            throw HVMError.ipc(.serverBindFailed(path: path, errno: saved))
        }

        self.listenFd = fd
        self.handler = handler

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "HVMIPC.accept"
        thread.start()
        self.acceptThread = thread
        Self.log.info("ipc server start: \(self.path, privacy: .public)")
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        if listenFd >= 0 {
            shutdown(listenFd, SHUT_RDWR)
            close(listenFd)
            listenFd = -1
        }
        unlink(path)
        Self.log.info("ipc server stop: \(self.path, privacy: .public)")
    }

    deinit { stop() }

    // MARK: - 内部 accept loop

    private func acceptLoop() {
        while !stopped {
            var peer = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFd, &peer, &len)
            if client < 0 {
                if stopped || errno == EBADF { return }
                if errno == EINTR { continue }
                continue
            }
            // 每连接一个线程 (M1 简化; 生产上限并发, 但 CLI 访问量很小)
            let conn = client
            Thread { [weak self] in
                self?.handleConnection(fd: conn)
                close(conn)
            }.start()
        }
    }

    private func handleConnection(fd: Int32) {
        guard let handler = self.handler else { return }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        while true {
            let raw: Data?
            do {
                raw = try Frame.read(fd: fd)
            } catch {
                return
            }
            guard let data = raw else { return }        // peer closed
            guard let req = try? decoder.decode(IPCRequest.self, from: data) else {
                let err = IPCResponse.failure(id: "", code: "ipc.decode_failed",
                                              message: "无法解析请求")
                if let d = try? encoder.encode(err) {
                    try? Frame.write(fd: fd, payload: d)
                }
                continue
            }
            // 协议版本校验: nil 视作 legacy 接受; != current 返 protocol_mismatch
            let resp: IPCResponse
            if let v = req.protoVersion, v != IPCProtocol.version {
                Self.log.warning("ipc protocol mismatch: client=\(v) server=\(IPCProtocol.version) op=\(req.op, privacy: .public)")
                resp = IPCResponse.failure(
                    id: req.id,
                    code: "ipc.protocol_mismatch",
                    message: "客户端协议版本 \(v) 与服务端 \(IPCProtocol.version) 不兼容, 请重启 HVM 或对齐二进制版本",
                    details: ["client": "\(v)", "server": "\(IPCProtocol.version)"]
                )
            } else {
                resp = handler(req)
            }
            if let d = try? encoder.encode(resp) {
                do { try Frame.write(fd: fd, payload: d) } catch { return }
            }
        }
    }
}
