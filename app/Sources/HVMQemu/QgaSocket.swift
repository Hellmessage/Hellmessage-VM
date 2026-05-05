// HVMQemu/QgaSocket.swift
//
// qemu-guest-agent (qga) Unix socket NDJSON 通路 — 收发 helpers.
// QgaExec / QgaFile 共用. 协议: 每条命令 / 响应是单行 JSON, '\n' 分隔.
//
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html

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

public enum QgaSocket {

    /// 连本地 Unix domain socket. 设 5s 读超时防 readJsonLine 永久 block.
    /// 调用方负责 `Darwin.close(fd)`.
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

    /// 发一条 JSON, 自动追 '\n'.
    public static func sendJsonLine(fd: Int32, obj: [String: Any]) throws {
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
    /// 16MiB 单 line 上限防 OOM.
    public static func readJsonLine(fd: Int32, deadline: Date) throws -> [String: Any] {
        var lineBuf = Data()
        while Date() < deadline {
            var byte: UInt8 = 0
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if Date() >= deadline { throw QgaError.timeout }
                    continue
                }
                throw QgaError.readFailed(reason: "recv errno=\(errno)")
            }
            if n == 0 { throw QgaError.readFailed(reason: "EOF before newline") }
            if byte == 0x0A {
                guard let obj = try? JSONSerialization.jsonObject(with: lineBuf) as? [String: Any] else {
                    throw QgaError.parseFailed(reason: "not JSON object: \(String(data: lineBuf, encoding: .utf8) ?? "<binary>")")
                }
                return obj
            }
            lineBuf.append(byte)
            if lineBuf.count > 16 * 1024 * 1024 {
                throw QgaError.parseFailed(reason: "line > 16MB")
            }
        }
        throw QgaError.timeout
    }

    /// 发一条 QGA 命令, 同步等响应一行. 自动判 `error` 字段抛 guestError.
    /// 返 `return` 字段 (可能是 dict / int / 其他 — 调用方按命令规约 cast).
    @discardableResult
    public static func call(
        fd: Int32, execute: String, arguments: [String: Any]? = nil,
        deadline: Date
    ) throws -> Any {
        var cmd: [String: Any] = ["execute": execute]
        if let arguments { cmd["arguments"] = arguments }
        try sendJsonLine(fd: fd, obj: cmd)
        let resp = try readJsonLine(fd: fd, deadline: deadline)
        if let err = resp["error"] as? [String: Any] {
            let klass = (err["class"] as? String) ?? "GenericError"
            let desc  = (err["desc"] as? String) ?? "\(err)"
            throw QgaError.guestError(klass: klass, desc: desc)
        }
        // QGA `return` 字段对无返回值的命令是 `{}`; 我们仍返这个空 dict.
        return resp["return"] ?? [String: Any]()
    }
}
