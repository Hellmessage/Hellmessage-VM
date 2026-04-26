// HVMIPC/SocketClient.swift
// hvm-cli / hvm-dbg 对 HVMHost 的同步客户端. 每次请求建立新连接, 简单且短命

import Foundation
import Darwin
import HVMCore

public final class SocketClient {
    public static func request(socketPath: String, request: IPCRequest, timeoutSec: Int = 10) throws -> IPCResponse {
        // 走 HVMCore/UnixSocket helper (含 SO_RCVTIMEO/SNDTIMEO + sockaddr_un 拼装 + connect).
        // 失败映射成 IPC 语义错误 (socketNotFound 优先于 connectionRefused, 给客户端更准提示).
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath, timeoutSec: timeoutSec)
        } catch UnixSocket.Error.connectFailed(_, let errnoVal) where errnoVal == ENOENT {
            throw HVMError.ipc(.socketNotFound(path: socketPath))
        } catch {
            throw HVMError.ipc(.connectionRefused(path: socketPath))
        }
        defer { close(fd) }

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
