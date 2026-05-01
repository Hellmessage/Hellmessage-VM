// HVMQemu/QgaExec.swift
//
// qemu-guest-agent (qga) 协议封装 — 通过 unix socket 在 guest 内跑 process 拿结果.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// 用途: hvm-dbg exec --via-qga 跑 PowerShell / cmd 等命令, 拿 stdout/stderr/exit_code.
// 不依赖 keyboard typing (避 IME 字符替换) / OCR (避识别误差) / GUI mouse (避 USB
// tablet 坐标问题) — 端到端自动化验证 guest 行为最可靠通路.
//
// 配套要求:
//   - argv 挂 chardev qga + virtserialport name=org.qemu.guest_agent.0 (QemuArgsBuilder
//     已支持 qgaSocketPath)
//   - guest 内装 qemu-ga.exe 服务 (UTM Guest Tools 装包含 qemu-ga-x86_64.msi)
//   - 服务自动连 \\.\Global\com.qemu.guest_agent.0 virtio-serial port

import Foundation
import Darwin

public enum QgaExec {

    public struct Result: Sendable {
        public let exitCode: Int
        public let stdoutBase64: String
        public let stderrBase64: String
    }

    public enum QgaError: Error, Sendable {
        case socketConnect(reason: String)
        case sendFailed(reason: String)
        case readFailed(reason: String)
        case parseFailed(reason: String)
        case execStartFailed(reason: String)
        case timeout
    }

    /// 跑 guest 内 process. 阻塞直到 process exit / 超时.
    /// path: binary 全路径 (e.g. "powershell.exe", "C:\\Windows\\System32\\cmd.exe")
    /// args: argv (path 之后的参数)
    /// timeoutSec: 整体超时, 含 launch + wait exit
    public static func run(
        socketPath: String, path: String, args: [String], timeoutSec: Int = 30
    ) async throws -> Result {
        let fd = try connectUnix(socketPath: socketPath)
        defer { Darwin.close(fd) }

        // 1. 发 guest-exec
        let execCmd: [String: Any] = [
            "execute": "guest-exec",
            "arguments": [
                "path": path,
                "arg": args,
                "capture-output": true,
            ] as [String: Any],
        ]
        try sendJsonLine(fd: fd, obj: execCmd)
        let execResp = try readJsonLine(fd: fd, deadline: Date().addingTimeInterval(5))
        guard let returnDict = execResp["return"] as? [String: Any],
              let pid = returnDict["pid"] as? Int else {
            throw QgaError.execStartFailed(reason: "guest-exec response missing pid: \(execResp)")
        }

        // 2. 轮询 guest-exec-status
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
        var pollInterval: useconds_t = 100_000  // 100ms
        let maxPollInterval: useconds_t = 1_000_000  // 1s
        while Date() < deadline {
            usleep(pollInterval)
            pollInterval = min(maxPollInterval, pollInterval * 2)
            let statusCmd: [String: Any] = [
                "execute": "guest-exec-status",
                "arguments": ["pid": pid],
            ]
            try sendJsonLine(fd: fd, obj: statusCmd)
            let statusResp = try readJsonLine(fd: fd, deadline: deadline)
            guard let ret = statusResp["return"] as? [String: Any] else { continue }
            let exited = (ret["exited"] as? Bool) ?? false
            if exited {
                let exitcode = (ret["exitcode"] as? Int) ?? -1
                let stdoutB64 = (ret["out-data"] as? String) ?? ""
                let stderrB64 = (ret["err-data"] as? String) ?? ""
                return Result(exitCode: exitcode, stdoutBase64: stdoutB64, stderrBase64: stderrB64)
            }
        }
        throw QgaError.timeout
    }

    // MARK: - 内部

    private static func connectUnix(socketPath: String) throws -> Int32 {
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
        // 设短读 timeout, 防 readJsonLine block 永久
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func sendJsonLine(fd: Int32, obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        var buf = data
        buf.append(0x0A)  // newline-delimited JSON
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
    private static func readJsonLine(fd: Int32, deadline: Date) throws -> [String: Any] {
        var lineBuf = Data()
        while Date() < deadline {
            var byte: UInt8 = 0
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // SO_RCVTIMEO 触发, 试再读
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
            // 防过长 line 撑爆
            if lineBuf.count > 16 * 1024 * 1024 {
                throw QgaError.parseFailed(reason: "line > 16MB")
            }
        }
        throw QgaError.timeout
    }
}
