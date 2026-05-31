// HVMQemu/QgaFile.swift
// qemu-guest-agent (qga) 文件 API 封装 — host ↔ guest 单文件 push / pull.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// 用途: hvm-dbg file push/pull / GUI "传文件到 VM". 走 QgaSocket (与 QgaExec 共用通路,
// 每次 push/pull 用独立连接). 性能 ~8-12 MB/s, 适合 < 100 MiB 偶发传输; 大文件由 timeout 兜底.
// 配套: VM 在跑 + qemu-ga 服务 attach + guest-file-* 未 blacklist.
// v1 限制: 单文件不递归; push 远端写入非原子 (中断留半成品); 大小校验由调用层 (CLI/GUI) 把关.

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

        let conn = try QgaSocket.connect(socketPath: socketPath)
        defer { conn.close() }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        let handle = try guestFileOpen(conn: conn, path: dstRemote, mode: "wb", deadline: deadline)

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
                try guestFileWriteAll(conn: conn, handle: handle, data: chunk, deadline: deadline)
                sent += Int64(chunk.count)
                progress?(sent, fileSize)
            }
            try guestFileFlush(conn: conn, handle: handle, deadline: deadline)
        } catch {
            pushError = error
        }

        // 关闭 remote handle (即便 push 失败也尝试关, 防 fd 泄漏 on guest 侧)
        try? guestFileClose(conn: conn, handle: handle, deadline: deadline)

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

        let conn = try QgaSocket.connect(socketPath: socketPath)
        defer { conn.close() }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        let handle = try guestFileOpen(conn: conn, path: srcRemote, mode: "rb", deadline: deadline)

        // SEEK_END 拿 total size, 再 SEEK_SET 回 0. 拿不到 (老 qemu-ga / non-seekable)
        // 也不致命, total 标 nil.
        let total: Int64?
        if let endPos = try? guestFileSeek(conn: conn, handle: handle, offset: 0, whence: 2, deadline: deadline),
           let _ = try? guestFileSeek(conn: conn, handle: handle, offset: 0, whence: 0, deadline: deadline) {
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
            try? guestFileClose(conn: conn, handle: handle, deadline: deadline)
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
                let r = try guestFileRead(conn: conn, handle: handle,
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
        try? guestFileClose(conn: conn, handle: handle, deadline: deadline)

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
        conn: QgaConnection, path: String, mode: String, deadline: Date
    ) throws -> Int {
        let ret = try conn.call(
            execute: "guest-file-open",
            arguments: ["path": path, "mode": mode],
            deadline: deadline
        )
        if let h = ret as? Int { return h }
        if let h = ret as? NSNumber { return h.intValue }
        throw QgaError.parseFailed(reason: "guest-file-open return not Int: \(ret)")
    }

    /// guest-file-close. 失败返协议错误, 不抛对调用方致命的错 (调用方多走 try?).
    public static func guestFileClose(
        conn: QgaConnection, handle: Int, deadline: Date
    ) throws {
        _ = try conn.call(
            execute: "guest-file-close",
            arguments: ["handle": handle],
            deadline: deadline
        )
    }

    /// guest-file-flush. 装包脚本可能 disable, 非致命 — caller 走 try? 即可.
    public static func guestFileFlush(
        conn: QgaConnection, handle: Int, deadline: Date
    ) throws {
        _ = try conn.call(
            execute: "guest-file-flush",
            arguments: ["handle": handle],
            deadline: deadline
        )
    }

    /// guest-file-seek. whence: 0=SET 1=CUR 2=END. 返 position (绝对偏移).
    public static func guestFileSeek(
        conn: QgaConnection, handle: Int, offset: Int64, whence: Int, deadline: Date
    ) throws -> Int64 {
        let ret = try conn.call(
            execute: "guest-file-seek",
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
        conn: QgaConnection, handle: Int, count: Int, deadline: Date
    ) throws -> ReadChunk {
        let ret = try conn.call(
            execute: "guest-file-read",
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

    /// guest-file-write. 一次 chunk; 服务端可能短写, 用 guestFileWriteAll 循环写满.
    public static func guestFileWrite(
        conn: QgaConnection, handle: Int, data: Data, deadline: Date
    ) throws -> Int {
        let b64 = data.base64EncodedString()
        let ret = try conn.call(
            execute: "guest-file-write",
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
        conn: QgaConnection, handle: Int, data: Data, deadline: Date
    ) throws {
        var off = 0
        while off < data.count {
            let slice = data.subdata(in: off..<data.count)
            let n = try guestFileWrite(conn: conn, handle: handle, data: slice, deadline: deadline)
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
