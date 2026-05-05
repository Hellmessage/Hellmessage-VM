// HVMQemu/QgaFile.swift
//
// qemu-guest-agent (qga) 文件 API 封装 — host ↔ guest 单文件 push / pull.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// 用途: hvm-dbg file push/pull / GUI Sharing 区"传文件到 VM" 等. 走 QgaSocket
// (chardev qga + virtio-serial port org.qemu.guest_agent.0), 与 QgaExec 共用 socket
// 通路 (但每次 push/pull 用独立连接, 不持久化).
//
// 性能预期: base64 + JSON 封装 + Unix socket 1 MiB chunk, 实测 8-12 MB/s 量级,
// 适合 < 100 MiB 偶发文件传输. 大文件 (> 1 GiB) 仍能跑但慢, 由 timeout 兜底.
//
// 配套要求:
//   - VM 在跑 + qemu-ga.exe 服务已 attach (Win UTM Guest Tools / Linux apt install)
//   - guest-file-* 在 qemu-ga blacklist 之外 (默认开放, 装包脚本不强制 disable)
//
// v1 限制 (设计稿 docs/v3/FILE_COPY.md):
//   - 单文件, 不递归
//   - 远端写入非原子 — 中断会留半成品 dst (调用方自决是否 .hvm-tmp + rename 兜底,
//     这层不掺合 OS 路径分隔符判定)
//   - 软警告 100 MiB / 硬上限 4 GiB 由调用层 (CLI / GUI) 把关, 这里不做大小校验

import Foundation
import Darwin

public enum QgaFile {

    /// host → guest push 单文件. 直接覆盖 dstRemote (mode "wb").
    /// - Parameters:
    ///   - socketPath: qga unix socket 全路径 (HVMPaths.qgaSocketPath(for:))
    ///   - srcLocal: host 本地源文件
    ///   - dstRemote: guest 内绝对路径 (Win: `C:\\path\\file`; Linux: `/path/file`)
    ///   - chunkSize: 每次 guest-file-write 的 raw 字节数, 默认 1 MiB
    ///   - timeoutSec: 整体超时, 含 open + 全部 chunk + close
    ///   - progress: 每写一个 chunk 回调 (bytesSent, totalBytes). 同步调用, 不要阻塞
    /// - Returns: 实际写入字节数 (= srcLocal 文件 size)
    @discardableResult
    public static func push(
        socketPath: String,
        srcLocal: URL,
        dstRemote: String,
        chunkSize: Int = 1 * 1024 * 1024,
        timeoutSec: Int = 600,
        progress: ((_ bytesSent: Int64, _ total: Int64) -> Void)? = nil
    ) async throws -> Int64 {

        let fileSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: srcLocal.path)
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw QgaError.guestError(klass: "LocalFileError",
                                      desc: "stat src failed: \(error.localizedDescription)")
        }

        let srcHandle: FileHandle
        do {
            srcHandle = try FileHandle(forReadingFrom: srcLocal)
        } catch {
            throw QgaError.guestError(klass: "LocalFileError",
                                      desc: "open src failed: \(error.localizedDescription)")
        }
        defer { try? srcHandle.close() }

        let fd = try QgaSocket.connectUnix(socketPath: socketPath)
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        let handle = try guestFileOpen(fd: fd, path: dstRemote, mode: "wb", deadline: deadline)

        var sent: Int64 = 0
        var pushError: Error?
        do {
            progress?(0, fileSize)
            while sent < fileSize {
                try Task.checkCancellation()
                let want = min(chunkSize, Int(fileSize - sent))
                guard let chunk = try? srcHandle.read(upToCount: want), !chunk.isEmpty else {
                    throw QgaError.guestError(klass: "LocalFileError",
                                              desc: "src read short at offset \(sent)")
                }
                try guestFileWriteAll(fd: fd, handle: handle, data: chunk, deadline: deadline)
                sent += Int64(chunk.count)
                progress?(sent, fileSize)
            }
            try guestFileFlush(fd: fd, handle: handle, deadline: deadline)
        } catch {
            pushError = error
        }

        // 关闭 remote handle (即便 push 失败也尝试关, 防 fd 泄漏 on guest 侧)
        try? guestFileClose(fd: fd, handle: handle, deadline: deadline)

        if let pushError { throw pushError }
        return sent
    }

    /// guest → host pull 单文件.
    /// 写到 `<dstLocal>.hvm-tmp.<hex8>` 再 rename, 中断不留半成品 (本地 rename atomic).
    @discardableResult
    public static func pull(
        socketPath: String,
        srcRemote: String,
        dstLocal: URL,
        chunkSize: Int = 1 * 1024 * 1024,
        timeoutSec: Int = 600,
        progress: ((_ bytesRead: Int64, _ total: Int64?) -> Void)? = nil
    ) async throws -> Int64 {

        let fd = try QgaSocket.connectUnix(socketPath: socketPath)
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        let handle = try guestFileOpen(fd: fd, path: srcRemote, mode: "rb", deadline: deadline)

        // SEEK_END 拿 total size, 再 SEEK_SET 回 0. 拿不到 (老 qemu-ga / non-seekable)
        // 也不致命, total 标 nil.
        let total: Int64?
        if let endPos = try? guestFileSeek(fd: fd, handle: handle, offset: 0, whence: 2, deadline: deadline),
           let _ = try? guestFileSeek(fd: fd, handle: handle, offset: 0, whence: 0, deadline: deadline) {
            total = endPos
        } else {
            total = nil
        }

        let tmpURL = dstLocal.deletingLastPathComponent()
            .appendingPathComponent(".\(dstLocal.lastPathComponent).hvm-tmp.\(randomHex8())")

        FileManager.default.createFile(atPath: tmpURL.path, contents: nil, attributes: nil)
        let dstHandle: FileHandle
        do {
            dstHandle = try FileHandle(forWritingTo: tmpURL)
        } catch {
            try? guestFileClose(fd: fd, handle: handle, deadline: deadline)
            throw QgaError.guestError(klass: "LocalFileError",
                                      desc: "open dst tmp failed: \(error.localizedDescription)")
        }

        var read: Int64 = 0
        var pullError: Error?
        do {
            progress?(0, total)
            var eof = false
            while !eof {
                try Task.checkCancellation()
                let r = try guestFileRead(fd: fd, handle: handle,
                                          count: chunkSize, deadline: deadline)
                if !r.data.isEmpty {
                    try dstHandle.write(contentsOf: r.data)
                    read += Int64(r.data.count)
                    progress?(read, total)
                }
                eof = r.eof
                if r.data.isEmpty && !r.eof {
                    // 防活锁: 没读到字节又没 eof, 跳出
                    break
                }
            }
        } catch {
            pullError = error
        }

        try? dstHandle.close()
        try? guestFileClose(fd: fd, handle: handle, deadline: deadline)

        if let pullError {
            try? FileManager.default.removeItem(at: tmpURL)
            throw pullError
        }

        do {
            // 覆盖目标: 老文件存在则替换
            if FileManager.default.fileExists(atPath: dstLocal.path) {
                _ = try FileManager.default.replaceItemAt(dstLocal, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: dstLocal)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw QgaError.guestError(klass: "LocalFileError",
                                      desc: "rename tmp → dst failed: \(error.localizedDescription)")
        }

        return read
    }

    // MARK: - QGA file API 单命令封装

    /// guest-file-open. mode 沿 fopen 语义: "r"/"rb"/"w"/"wb"/"a"/"ab".
    /// 返 handle (qga 内部 fd-like 句柄).
    public static func guestFileOpen(
        fd: Int32, path: String, mode: String, deadline: Date
    ) throws -> Int {
        let ret = try QgaSocket.call(
            fd: fd, execute: "guest-file-open",
            arguments: ["path": path, "mode": mode],
            deadline: deadline
        )
        if let h = ret as? Int { return h }
        if let h = ret as? NSNumber { return h.intValue }
        throw QgaError.parseFailed(reason: "guest-file-open return not Int: \(ret)")
    }

    /// guest-file-close. 失败返协议错误, 不抛对调用方致命的错 (调用方多走 try?).
    public static func guestFileClose(
        fd: Int32, handle: Int, deadline: Date
    ) throws {
        _ = try QgaSocket.call(
            fd: fd, execute: "guest-file-close",
            arguments: ["handle": handle],
            deadline: deadline
        )
    }

    /// guest-file-flush. 装包脚本可能 disable, 非致命 — caller 走 try? 即可.
    public static func guestFileFlush(
        fd: Int32, handle: Int, deadline: Date
    ) throws {
        _ = try QgaSocket.call(
            fd: fd, execute: "guest-file-flush",
            arguments: ["handle": handle],
            deadline: deadline
        )
    }

    /// guest-file-seek. whence: 0=SET 1=CUR 2=END. 返 position (绝对偏移).
    public static func guestFileSeek(
        fd: Int32, handle: Int, offset: Int64, whence: Int, deadline: Date
    ) throws -> Int64 {
        let ret = try QgaSocket.call(
            fd: fd, execute: "guest-file-seek",
            arguments: ["handle": handle, "offset": offset, "whence": whence],
            deadline: deadline
        )
        guard let dict = ret as? [String: Any] else {
            throw QgaError.parseFailed(reason: "guest-file-seek return not dict: \(ret)")
        }
        if let p = dict["position"] as? Int64 { return p }
        if let p = dict["position"] as? NSNumber { return p.int64Value }
        throw QgaError.parseFailed(reason: "guest-file-seek position missing: \(dict)")
    }

    public struct ReadChunk: Sendable {
        public let data: Data
        public let eof: Bool
    }

    /// guest-file-read. count 是请求字节, 返实际读到 (可能 < count, 也可能为 0 当 eof).
    public static func guestFileRead(
        fd: Int32, handle: Int, count: Int, deadline: Date
    ) throws -> ReadChunk {
        let ret = try QgaSocket.call(
            fd: fd, execute: "guest-file-read",
            arguments: ["handle": handle, "count": count],
            deadline: deadline
        )
        guard let dict = ret as? [String: Any] else {
            throw QgaError.parseFailed(reason: "guest-file-read return not dict: \(ret)")
        }
        let eof = (dict["eof"] as? Bool) ?? false
        let b64 = (dict["buf-b64"] as? String) ?? ""
        let data = b64.isEmpty ? Data() : (Data(base64Encoded: b64) ?? Data())
        if !b64.isEmpty && data.isEmpty {
            throw QgaError.parseFailed(reason: "guest-file-read buf-b64 not base64")
        }
        return ReadChunk(data: data, eof: eof)
    }

    /// guest-file-write. 一次 chunk; spec 上服务端可能短写 (Win), 用 guestFileWriteAll
    /// 包一层循环写满.
    public static func guestFileWrite(
        fd: Int32, handle: Int, data: Data, deadline: Date
    ) throws -> Int {
        let b64 = data.base64EncodedString()
        let ret = try QgaSocket.call(
            fd: fd, execute: "guest-file-write",
            arguments: ["handle": handle, "buf-b64": b64],
            deadline: deadline
        )
        guard let dict = ret as? [String: Any] else {
            throw QgaError.parseFailed(reason: "guest-file-write return not dict: \(ret)")
        }
        if let c = dict["count"] as? Int { return c }
        if let c = dict["count"] as? NSNumber { return c.intValue }
        throw QgaError.parseFailed(reason: "guest-file-write count missing: \(dict)")
    }

    /// 循环 guestFileWrite 直到 data 全写完 (兜短写; 多数情况下 1 次就完).
    public static func guestFileWriteAll(
        fd: Int32, handle: Int, data: Data, deadline: Date
    ) throws {
        var off = 0
        while off < data.count {
            let slice = data.subdata(in: off..<data.count)
            let n = try guestFileWrite(fd: fd, handle: handle, data: slice, deadline: deadline)
            if n <= 0 {
                throw QgaError.guestError(klass: "ShortWrite",
                                          desc: "guest-file-write returned \(n) at offset \(off)")
            }
            off += n
        }
    }

    // MARK: - 内部

    private static func randomHex8() -> String {
        var buf = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return buf.map { String(format: "%02x", $0) }.joined()
    }
}
