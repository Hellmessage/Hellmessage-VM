// HVMDisplayQemu/HVMFileClipboardBridge.swift
//
// UTM 风格 host → guest 文件剪贴板 — host 端的 JSON 协议 client.
//
// 通路: macOS Cmd+C 文件 → PasteboardBridge onFileURLs → publishFiles(urls)
//   → QGA push files to C:\ProgramData\HVM\clipboard\<sanitized>
//   → JSON 帧 {"op":"set-clipboard","paths":[...]} 发 virtio-serial socket
//   → guest hvm-guest-helper.exe 调 OleSetClipboard + CF_HDROP 设 Win clipboard.
//
// 设计要点:
//   - single-client unix socket (QEMU chardev server=on, 我们作 client); 独立 chardev 不抢
//   - JSON length-prefix framing (4-byte BE u32 length + body), 兼容 helper src/protocol.rs
//   - 单 in-flight request 串行, 不 pipeline (helper 单线程主循环)
//   - 连接断了不报错, 5s 重连, VM 重启 / helper 崩了都自动恢复

import Foundation
import Darwin
import OSLog
import os
import HVMQemu

private let log = Logger(subsystem: "com.hellmessage.vm", category: "FileClipboard")

public final class HVMFileClipboardBridge: @unchecked Sendable {

    /// 单 frame 最大 size (32 MiB), 跟 helper protocol.rs MAX_FRAME_BYTES 对齐.
    public static let maxFrameBytes: UInt32 = 32 * 1024 * 1024

    /// helper retry 是 5s, 我们 connect 失败也按这个周期重连.
    private static let reconnectDelaySec: TimeInterval = 5

    /// Guest 端 staging 目录 (world-writable/readable, 任何 user-session app 都能 paste 读).
    public static let guestStagingDir = #"C:\ProgramData\HVM\clipboard"#

    /// 单文件 1 GiB 软上限. 比 FILE_XFER 4 GiB 严些 (剪贴板期望 snappy, 大文件走 drag-drop).
    public static let maxFileSizeBytes: UInt64 = 1 * 1024 * 1024 * 1024

    /// staging 目录文件 TTL. 超过自动清掉. 24h 给跨重启 paste 复用.
    public static let stagingTTLHours: Int = 24

    /// 单次 publishFiles 整体超时 (上传 + setClipboard).
    public static let publishTimeoutSec: Int = 600

    private let socketPath: String
    /// QGA socket 路径. publishFiles 走 QGA push 上传文件到 guest staging dir.
    /// nil 时 fail-soft 不上传 (仅给单测用).
    private let qgaSocketPath: String?
    private let queue = DispatchQueue(label: "hvm.file-clipboard.client", qos: .userInitiated)
    /// queue 内访问. -1 = 未连接 / 已关.
    private var sockFD: Int32 = -1
    /// queue 内访问. 主动 stop 后置 true 阻 retry.
    private var stopped: Bool = false
    /// JSON id → 等响应的 continuation. 用 OSAllocatedUnfairLock (async-safe, Swift 6 严格并发兼容).
    /// read thread 在 handleFrame 里 resume; sendRequest 在 timeout 路径里 cancel.
    private let pending = OSAllocatedUnfairLock<[String: CheckedContinuation<Response, Error>]>(
        initialState: [:]
    )
    /// 自增 request id. queue 内访问.
    private var nextReqId: UInt32 = 1
    /// 读线程引用, 仅给 deinit 释放. 主动 stop 走 close socket 让 recv 立即返 0/-1 退出.
    private var readThread: Thread?

    public init(socketPath: String, qgaSocketPath: String? = nil) {
        self.socketPath = socketPath
        self.qgaSocketPath = qgaSocketPath
    }

    deinit {
        // close socket 让 read thread 出来 (read 返 0 → 自然退出)
        if sockFD >= 0 {
            Darwin.close(sockFD); sockFD = -1
        }
    }

    // MARK: - 公共生命周期

    /// 异步 connect chardev socket + 启动 read loop. 连不上不报错 silently retry.
    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.doConnect()
        }
    }

    /// 主动断开. 不再 retry. 任何挂着的请求 throw cancelled.
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.doDisconnect()
            self.failAllPendingLocked(reason: "bridge stopped")
        }
    }

    // MARK: - 公共 API (JSON ops)

    public enum BridgeError: Error, CustomStringConvertible {
        case notConnected
        case timeout(opName: String, sec: Int)
        case decodeFailed(String)
        case remoteFailure(code: String, message: String)
        case cancelled(String)

        public var description: String {
            switch self {
            case .notConnected: return "guest helper not connected"
            case .timeout(let op, let s): return "\(op) timeout after \(s)s"
            case .decodeFailed(let r): return "JSON decode failed: \(r)"
            case .remoteFailure(let c, let m): return "\(c): \(m)"
            case .cancelled(let r): return "cancelled: \(r)"
            }
        }
    }

    /// 探活. helper online 时 5s 内回, otherwise timeout.
    /// 返回 helper 自报 version (1.0.0+).
    public func ping(timeoutSec: Int = 5) async throws -> String {
        let resp = try await sendRequest(
            payload: ["op": "ping"], timeoutSec: timeoutSec
        )
        guard resp.ok else {
            throw BridgeError.remoteFailure(code: resp.code ?? "?", message: resp.message ?? "?")
        }
        return resp.version ?? "unknown"
    }

    /// 设 Win clipboard 为 CF_HDROP, 指向 paths (guest 端绝对路径). PR-3 调本方法前
    /// 先 QGA push 文件到这些路径.
    public func setClipboard(paths: [String], timeoutSec: Int = 30) async throws {
        let resp = try await sendRequest(
            payload: ["op": "set-clipboard", "paths": paths] as [String: Any],
            timeoutSec: timeoutSec
        )
        guard resp.ok else {
            throw BridgeError.remoteFailure(code: resp.code ?? "?", message: resp.message ?? "?")
        }
    }

    /// 清空 Win clipboard.
    public func clearClipboard(timeoutSec: Int = 5) async throws {
        let resp = try await sendRequest(
            payload: ["op": "clear-clipboard"], timeoutSec: timeoutSec
        )
        guard resp.ok else {
            throw BridgeError.remoteFailure(code: resp.code ?? "?", message: resp.message ?? "?")
        }
    }

    // MARK: - publishFiles (UTM-style paste-where-you-paste 主入口)

    /// 单次 publish 结果.
    public struct PublishResult: Sendable {
        public let successful: [String]   // 成功上传 + 通知 helper 的 host 路径
        public let skipped: [Skip]        // 拒上传 (文件夹 / 太大 / 不存在)
        public let failed: [Fail]         // 上传过程中错误
        /// 是否 helper 真的 ack 设了剪贴板 (false = 上传成功但 helper 没响应, 用户 Ctrl+V 不会有效果)
        public let clipboardSet: Bool
    }
    public struct Skip: Sendable {
        public let path: String
        public let reason: String
    }
    public struct Fail: Sendable {
        public let path: String
        public let reason: String
    }

    /// 主入口: PasteboardBridge.onFileURLs callback 调到这里. 边界: 文件夹 skip,
    /// 单文件 > 1 GiB skip + 提示走 drag-drop, 多文件串行上传.
    /// 流程: cleanup staging 老文件 → mkdir staging → 逐个 QGA push (文件名 sanitize)
    /// → setClipboard 让 helper 设 CF_HDROP → 返 PublishResult.
    public func publishFiles(_ urls: [URL]) async -> PublishResult {
        var success: [String] = []
        var skip: [Skip] = []
        var fail: [Fail] = []

        guard !urls.isEmpty else {
            return PublishResult(successful: [], skipped: [], failed: [], clipboardSet: false)
        }
        guard let qgaSocketPath = self.qgaSocketPath else {
            return PublishResult(
                successful: [], skipped: [],
                failed: urls.map { Fail(path: $0.path, reason: "qga socket 未注入") },
                clipboardSet: false
            )
        }

        fputs("HVMHost(qemu): HVMFileClipboardBridge.publishFiles urls=\(urls.count)\n", stderr)

        // Step 1: opportunistic cleanup (24h TTL). 失败不阻流程, 仅日志.
        do {
            try await cleanupStagingDir(qgaSocketPath: qgaSocketPath)
        } catch {
            log.warning("staging dir cleanup failed: \(String(describing: error), privacy: .public)")
        }

        // Step 2: ensure staging dir exists.
        do {
            try await ensureStagingDir(qgaSocketPath: qgaSocketPath)
        } catch {
            // 创建失败是硬错 — 后续 push 也会失败
            return PublishResult(
                successful: [], skipped: [],
                failed: urls.map { Fail(path: $0.path, reason: "create staging dir failed: \(error)") },
                clipboardSet: false
            )
        }

        // Step 3: 逐个文件 push. 文件夹 / 超大 skip.
        for url in urls {
            let path = url.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                skip.append(Skip(path: path, reason: "文件不存在"))
                continue
            }
            if isDir.boolValue {
                skip.append(Skip(path: path, reason: "暂不支持文件夹"))
                continue
            }
            let size: UInt64
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                guard let n = attrs[.size] as? NSNumber else {
                    skip.append(Skip(path: path, reason: "读取文件大小失败"))
                    continue
                }
                size = n.uint64Value
            } catch {
                skip.append(Skip(path: path, reason: "stat 失败: \(error)"))
                continue
            }
            if size > Self.maxFileSizeBytes {
                skip.append(Skip(path: path, reason: "文件 > 1 GiB, 请走 drag-drop"))
                continue
            }

            let sanitized = Self.sanitize(filename: url.lastPathComponent)
            let guestPath = #"\#(Self.guestStagingDir)\\#(sanitized)"#
            do {
                _ = try await QgaFile.push(
                    socketPath: qgaSocketPath,
                    srcLocal: url,
                    dstRemote: guestPath,
                    timeoutSec: Self.publishTimeoutSec,
                    progress: nil
                )
                success.append(guestPath)
                fputs("HVMHost(qemu): file-clipboard push ok: \(url.lastPathComponent) → \(guestPath)\n", stderr)
            } catch {
                fail.append(Fail(path: path, reason: "QGA push 失败: \(error)"))
            }
        }

        // Step 4: 通知 helper 设 clipboard (部分 push 失败时已成功的仍要让用户能 paste).
        var clipboardSet = false
        if !success.isEmpty {
            do {
                try await setClipboard(paths: success, timeoutSec: 30)
                clipboardSet = true
                fputs("HVMHost(qemu): file-clipboard setClipboard ok (\(success.count) files)\n", stderr)
            } catch {
                // helper 没响应 (未装 / 未启) 是常态. 没设 clipboard 则 paste 不到, 移到 failed.
                fputs("HVMHost(qemu): file-clipboard setClipboard 失败: \(error)\n", stderr)
                for p in success {
                    fail.append(Fail(path: p, reason: "guest helper 未响应: \(error)"))
                }
                success.removeAll()
            }
        }

        return PublishResult(
            successful: success, skipped: skip, failed: fail,
            clipboardSet: clipboardSet
        )
    }

    // MARK: - staging dir 管理 (QGA exec)

    /// 创建 staging dir. 已存在 idempotent.
    private func ensureStagingDir(qgaSocketPath: String) async throws {
        let ps = #"New-Item -ItemType Directory -Force -Path '\#(Self.guestStagingDir)' | Out-Null"#
        let result = try await QgaExec.run(
            socketPath: qgaSocketPath,
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", ps],
            timeoutSec: 30
        )
        if result.exitCode != 0 {
            throw BridgeError.remoteFailure(
                code: "ensure_staging_dir_failed",
                message: "exit=\(result.exitCode)"
            )
        }
    }

    /// 删 staging dir 中 mtime > 24h 的文件. 不删目录自身 / 不递归.
    private func cleanupStagingDir(qgaSocketPath: String) async throws {
        let ps = """
            $dir = '\(Self.guestStagingDir)'
            if (Test-Path $dir) {
                $cutoff = (Get-Date).AddHours(-\(Self.stagingTTLHours))
                Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue | \
                    Where-Object { $_.LastWriteTime -lt $cutoff } | \
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            """
        let result = try await QgaExec.run(
            socketPath: qgaSocketPath,
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", ps],
            timeoutSec: 30
        )
        // exit != 0 不抛 — cleanup 是 best-effort
        if result.exitCode != 0 {
            log.info("staging dir cleanup exit=\(result.exitCode, privacy: .public) (non-fatal)")
        }
    }

    /// 文件名 sanitize: Windows 非法字符 (: / \ < > " | ? *) → '_', 保留 .ext.
    /// 路径 traversal 防御 (lastPathComponent 已只是文件名, 这里再 strip 一次).
    static func sanitize(filename: String) -> String {
        let illegal: Set<Character> = [":", "/", "\\", "<", ">", "\"", "|", "?", "*"]
        var out = String()
        out.reserveCapacity(filename.count)
        for c in filename {
            if illegal.contains(c) || c.asciiValue == 0 {
                out.append("_")
            } else {
                out.append(c)
            }
        }
        // 不能空 / 不能 "."  / ".." (Windows 拒)
        if out.isEmpty || out == "." || out == ".." {
            out = "file-\(UUID().uuidString.prefix(8))"
        }
        // Windows 限单 path component ≤ 255 — sanitize 不保证长度, 截到 200 留余量给 staging dir 前缀
        if out.count > 200 {
            out = String(out.suffix(200))
        }
        return out
    }

    // MARK: - JSON 模型

    struct Response: Decodable {
        let id: String?
        let ok: Bool
        let version: String?
        let code: String?
        let message: String?
    }

    // MARK: - 内部: connect / read loop / 重连

    private func doConnect() {
        guard sockFD < 0, !stopped else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.warning("file-clipboard socket() failed errno=\(errno)")
            scheduleReconnect()
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            log.warning("file-clipboard socket path 太长: \(self.socketPath)")
            return
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
            // VM 启动早期 chardev socket 没就绪是常态 (ENOENT / ECONNREFUSED), 5s 后再试.
            log.info("file-clipboard connect errno=\(saved) path=\(self.socketPath) — 5s 后重试")
            scheduleReconnect()
            return
        }
        sockFD = fd
        log.info("file-clipboard connected to \(self.socketPath)")

        // read loop 独立 Thread 跑 blocking recv: 完整 frame → decode JSON → 按 id resume cont.
        let t = Thread { [weak self] in self?.runReadLoop() }
        t.name = "hvm.file-clipboard.read"
        readThread = t
        t.start()
    }

    private func doDisconnect() {
        if sockFD >= 0 {
            Darwin.close(sockFD); sockFD = -1
        }
        readThread = nil
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + Self.reconnectDelaySec) { [weak self] in
            self?.doConnect()
        }
    }

    private func runReadLoop() {
        let fd = sockFD   // snapshot
        guard fd >= 0 else { return }

        var rolling = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)

        while true {
            let n = buf.withUnsafeMutableBufferPointer { bp in
                Darwin.recv(fd, bp.baseAddress!, bufSize, 0)
            }
            if n == 0 {
                log.info("file-clipboard read EOF (helper 关连接 / chardev reset)")
                queue.async { [weak self] in
                    self?.handleDisconnect(reason: "EOF")
                }
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                log.warning("file-clipboard recv errno=\(errno), 退出 read loop")
                queue.async { [weak self] in
                    self?.handleDisconnect(reason: "recv errno=\(errno)")
                }
                return
            }
            rolling.append(buf, count: n)
            // 切尽量多的完整 frame
            while let frame = Self.tryConsumeFrame(&rolling) {
                handleFrame(frame)
            }
        }
    }

    /// 试图从 rolling buffer 切一个完整 frame. 不够长返 nil; 切走 frame 后 rolling 缩.
    private static func tryConsumeFrame(_ rolling: inout Data) -> Data? {
        guard rolling.count >= 4 else { return nil }
        let len = rolling.withUnsafeBytes { raw -> UInt32 in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
        }
        if len == 0 || len > maxFrameBytes {
            log.warning("file-clipboard 收到非法 frame len=\(len), drop rolling buffer")
            rolling.removeAll(keepingCapacity: false)
            return nil
        }
        let total = 4 + Int(len)
        guard rolling.count >= total else { return nil }
        let body = rolling.subdata(in: 4..<total)
        rolling.removeSubrange(0..<total)
        return body
    }

    private func handleFrame(_ body: Data) {
        let decoder = JSONDecoder()
        guard let resp = try? decoder.decode(Response.self, from: body) else {
            log.warning("file-clipboard JSON 解码失败 (\(body.count) bytes)")
            return
        }
        guard let id = resp.id else {
            log.warning("file-clipboard 响应无 id (\(body.count) bytes), 不知道唤醒谁")
            return
        }
        let cont = pending.withLock { $0.removeValue(forKey: id) }
        cont?.resume(returning: resp)
    }

    private func handleDisconnect(reason: String) {
        doDisconnect()
        failAllPendingLocked(reason: "disconnect (\(reason))")
        scheduleReconnect()
    }

    private func failAllPendingLocked(reason: String) {
        let conts: [String: CheckedContinuation<Response, Error>] = pending.withLock {
            let snapshot = $0
            $0.removeAll()
            return snapshot
        }
        for (_, cont) in conts {
            cont.resume(throwing: BridgeError.cancelled(reason))
        }
    }

    // MARK: - 内部: send

    /// 发一个请求, await response. 超时返 BridgeError.timeout, 连接断开返 cancelled.
    /// payload 必须含 "op" key; "id" 由本方法自动加.
    private func sendRequest(payload: [String: Any], timeoutSec: Int) async throws -> Response {
        let id = UUID().uuidString
        var body = payload
        body["id"] = id
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw BridgeError.decodeFailed("encode payload")
        }
        guard jsonData.count <= Int(Self.maxFrameBytes) else {
            throw BridgeError.decodeFailed("payload too large: \(jsonData.count)")
        }

        // 并发: 注册 pending → 写帧 → await continuation, 超时走 task group
        return try await withThrowingTaskGroup(of: Response.self) { group in
            // 主等待
            group.addTask { [weak self] in
                guard let self else { throw BridgeError.cancelled("self released") }
                return try await withCheckedThrowingContinuation { cont in
                    self.pending.withLock { $0[id] = cont }
                    // 异步发帧 (失败回 cont.throw)
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        guard self.sockFD >= 0 else {
                            let removed = self.pending.withLock { $0.removeValue(forKey: id) }
                            removed?.resume(throwing: BridgeError.notConnected)
                            return
                        }
                        if !self.sendFrame(jsonData) {
                            let removed = self.pending.withLock { $0.removeValue(forKey: id) }
                            removed?.resume(throwing: BridgeError.notConnected)
                            self.handleDisconnect(reason: "send failed")
                        }
                    }
                }
            }
            // 超时
            let opName = (payload["op"] as? String) ?? "?"
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
                throw BridgeError.timeout(opName: opName, sec: timeoutSec)
            }
            do {
                let r = try await group.next()!
                group.cancelAll()
                return r
            } catch {
                group.cancelAll()
                // 超时路径: 主等待 task 还在 await continuation, cancelAll 不唤醒它
                // (withCheckedThrowingContinuation 不响应 cancellation), 必须手动 resume.
                // continuation = nil 说明 read loop / send fail 已先 resume, 跳过.
                let removed = pending.withLock { $0.removeValue(forKey: id) }
                removed?.resume(throwing: BridgeError.cancelled("op timeout, request cancelled"))
                throw error
            }
        }
    }

    /// queue 内调用. 4-byte BE u32 length + JSON body. 失败返 false.
    private func sendFrame(_ body: Data) -> Bool {
        let len = UInt32(body.count)
        var header = Data(capacity: 4)
        header.append(UInt8((len >> 24) & 0xFF))
        header.append(UInt8((len >> 16) & 0xFF))
        header.append(UInt8((len >> 8) & 0xFF))
        header.append(UInt8(len & 0xFF))
        return sendAll(header) && sendAll(body)
    }

    private func sendAll(_ buf: Data) -> Bool {
        return buf.withUnsafeBytes { ptr -> Bool in
            var off = 0
            let total = buf.count
            while off < total {
                let r = Darwin.send(sockFD,
                                     ptr.baseAddress!.advanced(by: off),
                                     total - off, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += r
            }
            return true
        }
    }
}
