// HVMIPC/SocketClient.swift
// hvm-cli / hvm-dbg 对 HVMHost 的同步客户端. 每次请求建立新连接, 简单且短命

import Foundation
import Darwin
import HVMCore

public final class SocketClient {
    public static func request(socketPath: String, request: IPCRequest, timeoutSec: Int = 10) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HVMError.ipc(.connectionRefused(path: socketPath))
        }
        defer { close(fd) }

        // 超时 (读写各自 SO_RCVTIMEO / SO_SNDTIMEO)
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HVMError.ipc(.connectionRefused(path: socketPath))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        guard rc == 0 else {
            if errno == ENOENT {
                throw HVMError.ipc(.socketNotFound(path: socketPath))
            }
            throw HVMError.ipc(.connectionRefused(path: socketPath))
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        try Frame.write(fd: fd, payload: data)

        guard let respData = try Frame.read(fd: fd) else {
            throw HVMError.ipc(.readFailed(reason: "peer closed before response"))
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(IPCResponse.self, from: respData)
        } catch {
            throw HVMError.ipc(.decodeFailed(reason: "\(error)"))
        }
    }
}
