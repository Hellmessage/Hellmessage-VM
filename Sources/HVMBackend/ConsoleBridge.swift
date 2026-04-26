// HVMBackend/ConsoleBridge.swift
// guest virtio-console (hvc0) 的 host 侧桥接.
// 替代 makeSerialAttachment 的 (/dev/null + 文件) 单向写: 双向 pipe + tee 到日志 + ring buffer.
//
// 数据流:
//   guest stdout ─── pipe ───▶ host reader ───┬───▶ console-YYYY-MM-DD.log (append)
//                                              └───▶ ringBuffer (供 hvm-dbg console --read)
//   hvm-dbg console --write "..." ──IPC──▶ bridge.write ──▶ pipe ──▶ guest stdin
//
// 设计取舍:
//   - ringBuffer 上限 256 KiB. 超过后旧数据丢弃, 但保留 totalBytes 计数, 客户端用 sinceBytes
//     轮询时若窗口外, bridge 返回 ringBuffer 全量 + 真实 totalBytes 让客户端自洽.
//   - 跨天切日志: 每次写入前比对当天日期, 不同则关旧 fd 开新 fd. VM 跑 24h+ 不会无限堆同一文件.
//   - reader thread: 用 DispatchSourceRead 监听 host_read_fd, 高频小包足够.
//   - 关闭时序: VM 停 → close() 关 fds → reader source cancel → log handle close.

import Foundation

public final class ConsoleBridge: @unchecked Sendable {
    /// host 侧写入 (写到 guest stdin). VZ 拿对端 read fd 当 fileHandleForReading
    private let hostWriteHandle: FileHandle
    /// host 侧读取 (从 guest stdout 来). VZ 拿对端 write fd 当 fileHandleForWriting
    private let hostReadHandle: FileHandle
    /// 日志文件目录 (bundle/logs/), 跨天切到 console-<新日期>.log
    private let logsDir: URL
    /// 当前 append 中的日志文件 fd
    private var logHandle: FileHandle?
    /// 当前文件对应的 0 点 Date, 用来判断是否该切
    private var currentDay: Date = .distantPast
    /// ringBuffer 容量上限
    private static let ringCapacity = 256 * 1024
    /// 读取源
    private var readSource: DispatchSourceRead?
    /// 互斥锁保护 ringBuffer + totalBytes + logHandle
    private let lock = NSLock()
    /// guest 输出累计字节数 (从 VM 启动至今, 跨 ringBuffer 截断仍累加)
    private var totalBytesValue: Int = 0
    /// 最近 ringCapacity 字节的 guest 输出
    private var ringBuffer = Data()
    /// 是否已关闭
    private var closed = false

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// VZ 用的 attachment 配对 (read/write FileHandle 各一个).
    /// 两端是 pipe, fd lifecycle 由 ConsoleBridge 管理.
    public let vzReadHandle: FileHandle
    public let vzWriteHandle: FileHandle

    /// - Parameter logsDir: bundle/logs/, 内部按当天日期写 console-<yyyy-MM-dd>.log
    public init(logsDir: URL) throws {
        // pipe1: host → guest (host 写, VZ 读 → 转给 guest stdin)
        var hostToGuest: [Int32] = [-1, -1]
        guard pipe(&hostToGuest) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "pipe(host→guest) 失败"])
        }
        // pipe2: guest → host (VZ 写 guest stdout, host 读)
        var guestToHost: [Int32] = [-1, -1]
        guard pipe(&guestToHost) == 0 else {
            Darwin.close(hostToGuest[0]); Darwin.close(hostToGuest[1])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "pipe(guest→host) 失败"])
        }
        self.hostWriteHandle = FileHandle(fileDescriptor: hostToGuest[1], closeOnDealloc: true)
        self.vzReadHandle    = FileHandle(fileDescriptor: hostToGuest[0], closeOnDealloc: true)
        self.vzWriteHandle   = FileHandle(fileDescriptor: guestToHost[1], closeOnDealloc: true)
        self.hostReadHandle  = FileHandle(fileDescriptor: guestToHost[0], closeOnDealloc: true)

        self.logsDir = logsDir
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        // logHandle 在第一次 appendToRing 时按当天日期 lazy 打开 (避免 init 时机太早)

        startReader()
    }

    deinit {
        readSource?.cancel()
        if !closed { try? logHandle?.close() }
    }

    /// 由 VM 停止时调用, 关闭桥接.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        try? hostWriteHandle.close()
        try? logHandle?.close()
        logHandle = nil
        // hostReadHandle / vz* 的 fd 由 FileHandle(closeOnDealloc:true) 回收
    }

    /// hvm-dbg console --write 的入口.
    public func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else {
            throw NSError(domain: "ConsoleBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "console bridge 已关闭"])
        }
        try hostWriteHandle.write(contentsOf: data)
    }

    /// hvm-dbg console --read 的入口.
    /// - Parameter sinceBytes: 客户端上次拿到的 totalBytes 起点 (0 表示要全量当前缓冲)
    /// - Returns:
    ///   - data: 实际返回的字节
    ///   - totalBytes: 截至当前的 guest 输出累计字节数
    ///   - returnedSinceBytes: 本次返回数据的实际起点 (sinceBytes 落在 ring 窗口外时会上调到窗口左界)
    public func read(sinceBytes: Int) -> (data: Data, totalBytes: Int, returnedSinceBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let total = totalBytesValue
        let windowLeft = max(0, total - ringBuffer.count)
        let from = max(sinceBytes, windowLeft)
        guard from < total else {
            return (Data(), total, from)
        }
        let offsetInRing = from - windowLeft
        let slice = ringBuffer.subdata(in: offsetInRing..<ringBuffer.count)
        return (slice, total, from)
    }

    // MARK: - private

    private func startReader() {
        let fd = hostReadHandle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // 一次最多读 16KB, 减少 syscall 次数
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            let chunk = Data(bytes: buf, count: n)
            self.appendChunk(chunk)
        }
        source.setCancelHandler { [weak self] in
            try? self?.hostReadHandle.close()
        }
        source.resume()
        self.readSource = source
    }

    /// 收到 guest 输出 chunk: 写日志 (跨天 rotate) + append 到 ringBuffer.
    private func appendChunk(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }

        // 跨天切日志: 比对当天 0 点 Date, 不同则关旧 fd 开新文件
        let today = Calendar.current.startOfDay(for: Date())
        if today != currentDay || logHandle == nil {
            try? logHandle?.synchronize()
            try? logHandle?.close()
            logHandle = nil
            let dayStr = Self.dayFmt.string(from: today)
            let url = logsDir.appendingPathComponent("console-\(dayStr).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: url) {
                try? fh.seekToEnd()
                logHandle = fh
            }
            currentDay = today
        }

        try? logHandle?.write(contentsOf: chunk)

        totalBytesValue += chunk.count
        ringBuffer.append(chunk)
        if ringBuffer.count > Self.ringCapacity {
            ringBuffer.removeFirst(ringBuffer.count - Self.ringCapacity)
        }
    }
}
