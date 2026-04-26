// HVMCore/UnixSocket.swift
// 公共 unix domain socket 客户端 connect helper.
// HVMIPC SocketClient / HVMQemu QmpClient / QemuConsoleBridge 都依赖.
//
// 为什么放 HVMCore: socket 是底层基础设施, HVMCore 是最低层 module 所有 socket 用户都依赖;
// 不放 HVMIPC 因为 HVMQemu 不依赖 HVMIPC, 不放 HVMQemu 因为 HVMIPC 不依赖 HVMQemu.
//
// 不做 server 端 (bind/listen/accept), 那个由各自实现 (SocketServer / FakeQmpServer 测试).

import Foundation
import Darwin

public enum UnixSocket {

    public enum Error: Swift.Error, Sendable, Equatable {
        /// socket(2) 失败 (典型: 系统 fd 耗尽)
        case openFailed(errno: Int32)
        /// connect(2) 失败 (典型: 文件不存在 ENOENT, peer 没 listen ECONNREFUSED)
        case connectFailed(reason: String, errno: Int32)
        /// path 字节长度 ≥ sizeof(sockaddr_un.sun_path) (~104) 装不下
        case pathTooLong(length: Int)
    }

    /// 打开 AF_UNIX SOCK_STREAM, connect 到 path. 成功返 fd, 失败抛 Error.
    /// 调用方负责后续 Darwin.close(fd).
    /// timeoutSec: 非 nil → 设 SO_RCVTIMEO + SO_SNDTIMEO (粗粒度阻塞 IO 超时); nil 不设
    public static func connect(to path: String, timeoutSec: Int? = nil) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Error.openFailed(errno: errno)
        }

        if let timeoutSec {
            var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw Error.pathTooLong(length: pathBytes.count)
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
                Darwin.connect(fd, sa, addrLen)
            }
        }
        guard rc == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw Error.connectFailed(reason: "connect \(path)", errno: saved)
        }
        return fd
    }
}
