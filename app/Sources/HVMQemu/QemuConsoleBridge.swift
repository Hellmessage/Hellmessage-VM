// HVMQemu/QemuConsoleBridge.swift
// QEMU guest serial console 的 host 侧桥接 (与 HVMBackend/ConsoleBridge VZ 版同形态).
//
// 数据流:
//   QEMU -serial chardev:cons0 → unix socket (QEMU server)
//                                ▲
//                                │ connect (HVMHost client)
//   guest stdout ─── socket recv ───┬───▶ console-YYYY-MM-DD.log (append, 跨天切)
//                                    └───▶ ringBuffer (供 hvm-dbg console.read)
//   hvm-dbg console.write ──IPC──▶ bridge.write ──▶ socket send ──▶ guest stdin
//
// 与 VZ ConsoleBridge 的差异:
//   - VZ 用 pipe + FileHandle, attach 给 VZVirtualSerialPortConfiguration
//   - QEMU 用 unix socket client (我们 connect 上 QEMU server 端)
//   - ringBuffer / 日志 / read(sinceBytes:) 行为完全一致

import Foundation
import Darwin
import os.lock
import HVMCore

public final class QemuConsoleBridge: @unchecked Sendable {

    public enum BridgeError: Error, Sendable, Equatable {
        case socketOpenFailed(errno: Int32)
        case socketConnectFailed(reason: String, errno: Int32)
        case alreadyClosed
        case writeFailed(wrote: Int, expected: Int, errno: Int32)
    }

    private static let ringCapacity = 256 * 1024

    public let socketPath: String
    public let logsDir: URL

    private struct State {
        var fd: Int32 = -1
        var closed = false
        var totalBytes: Int = 0
        var ringBuffer = Data()
        var logHandle: FileHandle?
        var currentDay: Date = .distantPast
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    public init(socketPath: String, logsDir: URL) {
        self.socketPath = socketPath
        self.logsDir = logsDir
        self.readQueue = DispatchQueue(label: "hvm.qemu.console.read.\(UUID().uuidString.prefix(8))",
                                       qos: .utility)
        self.writeQueue = DispatchQueue(label: "hvm.qemu.console.write.\(UUID().uuidString.prefix(8))",
                                        qos: .utility)
    }

    deinit {
        let f = state.withLock { $0.fd }
        if f >= 0 { Darwin.close(f) }
    }

    /// 连接 QEMU 端 socket 并启动 reader. 调用方应在 QEMU 进程启动后再调.
    /// 失败抛 socketConnectFailed (典型: socket 文件还没出现 — 调用方应 poll-wait).
    public func connect() throws {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // 走 HVMCore/UnixSocket helper, 失败映射到 BridgeError 保留语义.
        let f: Int32
        do {
            f = try UnixSocket.connect(to: socketPath)
        } catch UnixSocket.Error.openFailed(let e) {
            throw BridgeError.socketOpenFailed(errno: e)
        } catch UnixSocket.Error.pathTooLong {
            throw BridgeError.socketConnectFailed(reason: "socket path 太长", errno: 0)
        } catch UnixSocket.Error.connectFailed(let reason, let e) {
            throw BridgeError.socketConnectFailed(reason: reason, errno: e)
        }

        state.withLock { $0.fd = f }
        readQueue.async { [weak self] in self?.readLoop() }
    }

    /// 关闭桥接. 幂等.
    public func close() {
        let (alreadyClosed, fdToClose, logHandle) = state.withLock { s -> (Bool, Int32, FileHandle?) in
            if s.closed { return (true, -1, nil) }
            s.closed = true
            let f = s.fd
            s.fd = -1
            let lh = s.logHandle
            s.logHandle = nil
            return (false, f, lh)
        }
        if alreadyClosed { return }
        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            Darwin.close(fdToClose)
        }
        try? logHandle?.close()
    }

    /// hvm-dbg console.write — 写字节到 guest stdin.
    public func write(_ data: Data) throws {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else { throw BridgeError.alreadyClosed }
        let f = state.withLock { $0.fd }
        guard f >= 0 else { throw BridgeError.alreadyClosed }
        let n = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return send(f, base, buf.count, 0)
        }
        guard n == data.count else {
            throw BridgeError.writeFailed(wrote: n, expected: data.count, errno: errno)
        }
    }

    /// hvm-dbg console.read — 增量拉.
    /// sinceBytes 落在 ring 窗口外时上调到窗口左界, 调用方读 returnedSinceBytes 自洽.
    public func read(sinceBytes: Int) -> (data: Data, totalBytes: Int, returnedSinceBytes: Int) {
        return state.withLock { s -> (Data, Int, Int) in
            let total = s.totalBytes
            let windowLeft = max(0, total - s.ringBuffer.count)
            let from = max(sinceBytes, windowLeft)
            guard from < total else {
                return (Data(), total, from)
            }
            let offsetInRing = from - windowLeft
            let slice = s.ringBuffer.subdata(in: offsetInRing..<s.ringBuffer.count)
            return (slice, total, from)
        }
    }

    // MARK: - 内部

    private func readLoop() {
        let f = state.withLock { $0.fd }
        if f < 0 { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return recv(f, base, ptr.count, 0)
            }
            if n <= 0 {
                // EOF / 错误 / shutdown — 退 loop, 不关 fd (close() 会处理)
                return
            }
            let data = Data(bytes: chunk, count: n)
            appendRingAndLog(data)
        }
    }

    private func appendRingAndLog(_ data: Data) {
        state.withLock { s in
            s.totalBytes += data.count
            s.ringBuffer.append(data)
            if s.ringBuffer.count > Self.ringCapacity {
                let drop = s.ringBuffer.count - Self.ringCapacity
                s.ringBuffer.removeSubrange(0..<drop)
            }
            // 跨天切日志
            let now = Date()
            let cal = Calendar.current
            let nowDay = cal.startOfDay(for: now)
            if !cal.isDate(s.currentDay, inSameDayAs: now) {
                try? s.logHandle?.close()
                let name = "console-\(Self.dayFmt.string(from: now)).log"
                let url = logsDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                if let h = try? FileHandle(forWritingTo: url) {
                    _ = try? h.seekToEnd()
                    s.logHandle = h
                }
                s.currentDay = nowDay
            }
            try? s.logHandle?.write(contentsOf: data)
        }
    }
}
