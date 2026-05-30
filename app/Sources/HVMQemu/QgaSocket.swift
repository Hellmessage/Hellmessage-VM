// HVMQemu/QgaSocket.swift
// qemu-guest-agent (qga) Unix socket NDJSON 通路 — 收发 helpers, QgaExec / QgaFile 共用.
// 协议: 每条命令 / 响应是单行 JSON, '\n' 分隔.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// **关键**: 走 `QgaConnection` 类持 recv 缓冲, 单次 recv 拉 64 KiB 扫 '\n' 切行, 余字节留给
// 下一行. 不能退回一字节一字节 recv — guest-file-read 的 ~1.4 MiB 响应会触发 ~1.4M 次 syscall, pull 卡死.

import Foundation
import Darwin

/// QGA 协议层错误. 一类是 socket / 协议层失败 (这里抛), 一类是
/// guest 内业务失败 (走 JSON `error` 字段, 由调用层判).
public enum QgaError: Error, Sendable {
    case socketConnect(reason: String)
    case sendFailed(reason: String)
    case readFailed(reason: String)
    case parseFailed(reason: String)
    /// guest-exec 启动失败 (拿不到 pid)
    case execStartFailed(reason: String)
    /// guest-file-* 业务失败 (qga 返 JSON `error` 字段, 例如 path 不存在 / blacklisted)
    case guestError(klass: String, desc: String)
    case timeout
}

/// 单条 qga unix socket 连接 + per-connection recv 缓冲. 多条 call (pull/push 循环) 必须
/// 走这个类共享缓冲, 不要绕过用裸 fd (跨 call 会漏读上一行 '\n' 后的字节).
/// owns=true (默认): deinit 时 close fd; owns=false: 调用方负责 close.
public final class QgaConnection {

    public let fd: Int32
    private var recvBuf = Data()
    private var owns: Bool

    public init(fd: Int32, owns: Bool = true) {
        self.fd = fd
        self.owns = owns
    }

    deinit {
        if owns { Darwin.close(fd) }
    }

    /// 主动关. 重复调用安全.
    public func close() {
        if owns {
            Darwin.close(fd)
            owns = false
        }
    }

    /// 发一条 JSON, 自动追 '\n'.
    public func sendJsonLine(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        var buf = data
        buf.append(0x0A)
        try buf.withUnsafeBytes { ptr -> Void in
            var off = 0
            while off < buf.count {
                let r = Darwin.send(fd, ptr.baseAddress!.advanced(by: off), buf.count - off, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    throw QgaError.sendFailed(reason: "send errno=\(errno)")
                }
                off += r
            }
        }
    }

    /// 读一行 (\n 结尾) JSON 并 parse. deadline 内总阻塞.
    /// 64 KiB chunked recv + per-connection 缓冲; 16 MiB 单 line 上限防 OOM.
    public func readJsonLine(deadline: Date) throws -> [String: Any] {
        let chunkSize = 64 * 1024
        while true {
            // 1) 先扫现有 buffer 里是否已经有一整行
            if let nlIdx = recvBuf.firstIndex(of: 0x0A) {
                let lineData = recvBuf[..<nlIdx]
                // Data slice startIndex 不一定是 0, 用 Data(lineData) 显式拷出独立 Data
                guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                    let s = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
                    // 推进缓冲跳过这行 + 然后报错 (防一直卡死在坏行)
                    recvBuf.removeSubrange(...nlIdx)
                    throw QgaError.parseFailed(reason: "not JSON object: \(s)")
                }
                // 推进缓冲跳过这行 + '\n'
                recvBuf.removeSubrange(...nlIdx)
                return obj
            }
            // 2) 没整行: 看是否过 16 MiB 上限
            if recvBuf.count > 16 * 1024 * 1024 {
                throw QgaError.parseFailed(reason: "line > 16MB without newline")
            }
            // 3) 拉一拨字节
            if Date() >= deadline { throw QgaError.timeout }
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let n = chunk.withUnsafeMutableBufferPointer { bp -> Int in
                return Darwin.recv(fd, bp.baseAddress, bp.count, 0)
            }
            if n > 0 {
                recvBuf.append(chunk, count: n)
            } else if n == 0 {
                throw QgaError.readFailed(reason: "EOF before newline")
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if Date() >= deadline { throw QgaError.timeout }
                    continue
                }
                throw QgaError.readFailed(reason: "recv errno=\(errno)")
            }
        }
    }

    /// 发一条 QGA 命令, 同步等响应一行. 自动判 `error` 字段抛 guestError.
    /// 返 `return` 字段 (可能是 dict / int / 其他 — 调用方按命令规约 cast).
    @discardableResult
    public func call(
        execute: String, arguments: [String: Any]? = nil,
        deadline: Date
    ) throws -> Any {
        var cmd: [String: Any] = ["execute": execute]
        if let arguments { cmd["arguments"] = arguments }
        try sendJsonLine(cmd)
        let resp = try readJsonLine(deadline: deadline)
        if let err = resp["error"] as? [String: Any] {
            let klass = (err["class"] as? String) ?? "GenericError"
            let desc  = (err["desc"] as? String) ?? "\(err)"
            throw QgaError.guestError(klass: klass, desc: desc)
        }
        // QGA `return` 字段对无返回值的命令是 `{}`; 我们仍返这个空 dict.
        return resp["return"] ?? [String: Any]()
    }
}

public enum QgaSocket {

    /// 连本地 Unix domain socket 拿 raw fd. 设 5s 读超时防 readJsonLine 永久 block.
    /// 调用方负责 close (或包进 QgaConnection 自动管).
    public static func connectUnix(socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw QgaError.socketConnect(reason: "socket() errno=\(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            throw QgaError.socketConnect(reason: "socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathLimit) { bp in
                for (i, b) in pathBytes.enumerated() { bp[i] = b }
                bp[pathBytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let saved = errno
            Darwin.close(fd)
            throw QgaError.socketConnect(reason: "connect errno=\(saved) path=\(socketPath)")
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// connect + 包成 QgaConnection. 推荐入口 (共享 recv 缓冲).
    public static func connect(socketPath: String) throws -> QgaConnection {
        let fd = try connectUnix(socketPath: socketPath)
        return QgaConnection(fd: fd, owns: true)
    }
}
