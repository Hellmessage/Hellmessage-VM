// HVMDisplayQemu/HVMFileClipboardBridge.swift
//
// UTM 风格 host → guest 文件剪贴板 — host 端的 JSON 协议 client.
// 详见 docs/v3/HOST_FILE_CLIPBOARD.md.
//
// 通路:
//   macOS Cmd+C 文件 → PasteboardBridge 通知 (走独立 onFileURLs callback)
//   → HVMFileClipboardBridge.publishFiles(urls)
//     ├─ (PR-3) QGA push files to C:\ProgramData\HVM\clipboard\<sanitized>
//     └─ JSON 帧 {"op":"set-clipboard","paths":[<guest 端绝对路径>]}
//        发到 virtio-serial socket → guest hvm-guest-helper.exe 收
//        → 调 OleSetClipboard + CF_HDROP 设 Win user clipboard
//
// 关键设计点:
//   - 跟 SpiceWebdavServer 同款 single-client unix socket model (QEMU chardev server=on,
//     我们作 client). 跟 vdagent / qga / webdav 独立 chardev, 互不抢
//   - JSON length-prefix framing (4-byte BE u32 length + body), 跟 HVMIPC/Frame.swift 同款,
//     兼容 hvm-guest-helper crate src/protocol.rs (上游已实现)
//   - 单 in-flight request: 当前不允许 pipeline, 一条 req 一条 resp 串行. 简化心智 +
//     避免 helper 端混乱 (helper 也是单线程主循环)
//   - 连接断了不报错, 主动 retry 5s 重连 (跟 guest helper 主循环同款). 这样 VM 重启 /
//     helper 崩了再起都自动恢复
//
// PR-2 范围: 只实 chardev socket + JSON 协议 client + ping/set/clear 三 op. 不接 QGA
// 上传 (PR-3 做) 也不接 PasteboardBridge 回调 (PR-3 wire). 这次 commit 是 server 端独立可测.

import Foundation
import Darwin
import OSLog
import os

private let log = Logger(subsystem: "com.hellmessage.vm", category: "FileClipboard")

public final class HVMFileClipboardBridge: @unchecked Sendable {

    /// 单 frame 最大 size (32 MiB), 跟 helper protocol.rs MAX_FRAME_BYTES 对齐.
    public static let maxFrameBytes: UInt32 = 32 * 1024 * 1024

    /// helper retry 是 5s, 我们 connect 失败也按这个周期重连.
    private static let reconnectDelaySec: TimeInterval = 5

    private let socketPath: String
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

    public init(socketPath: String) {
        self.socketPath = socketPath
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
            // VM 启动早期 chardev socket 还没就绪是常态, 5s 后再试.
            // ENOENT (2) 或 ECONNREFUSED (61) 都正常.
            log.info("file-clipboard connect errno=\(saved) path=\(self.socketPath) — 5s 后重试")
            scheduleReconnect()
            return
        }
        sockFD = fd
        log.info("file-clipboard connected to \(self.socketPath)")

        // read loop 独立 Thread 跑 blocking recv. 收到完整 frame → decode JSON →
        // 通过 id resume continuation.
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
                // 清 pending entry (timeout 路径 read loop 不会再消费这个 id).
                // 注意: 如果 continuation 还没 resume, removeValue 拿到的 cont 不能 resume
                // (要么主等待 task 已 resume 它, 要么是孤儿 continuation; CheckedContinuation
                // 文档明确禁止"resume after thrown / cancelled task"). 这里只 remove 不 resume.
                _ = pending.withLock { $0.removeValue(forKey: id) }
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
