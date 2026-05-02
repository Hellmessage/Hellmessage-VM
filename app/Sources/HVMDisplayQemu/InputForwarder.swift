// InputForwarder.swift
//
// 通过 QMP `input-send-event` 命令把 host 端键鼠事件转发给 QEMU guest.
//
// 设计要点:
//   1. **独立** QMP socket 连接, 不复用 HVMQemu 的控制 QMP — 避免 accept 争抢
//      和并发命令 stream 解析复杂度. QEMU argv 必须额外暴露一个
//      `-qmp unix:<path>.input,server=on,wait=off` socket 给本类.
//   2. 单连接 + serial DispatchQueue: 所有 send 串行化, sendmsg 不能并发.
//   3. 简化握手: connect → drain greeting (单行 JSON) → 发 qmp_capabilities
//      → drain return → ready. server 后续推送的 event 全部 drain 丢弃.
//   4. 鼠标坐标用绝对坐标空间 (0..32767), QEMU `usb-tablet` / `virtio-tablet`
//      的标准做法; 调用方传 NSView 内的 viewX / viewY, 由本类按 viewSize
//      归一化, 并去重 (同一坐标重复不发).
//
// QMP `input-send-event` 命令 payload (上游 qapi/ui.json `InputEvent`):
//   { "execute": "input-send-event",
//     "arguments": { "events": [
//        { "type": "key", "data": { "down": true,
//                                    "key": { "type": "qcode", "data": "a" } } },
//        { "type": "abs", "data": { "axis": "x", "value": 16383 } },
//        { "type": "btn", "data": { "down": true, "button": "left" } }
//     ] } }

import Foundation
import Darwin
import os

/// QMP 输入事件转发器. 一个 VM 实例一个.
public final class InputForwarder: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.hellmessage.vm", category: "InputForwarder")

    /// QEMU 支持的鼠标键名 (上游 InputButton enum).
    public enum MouseButton: String, Sendable {
        case left      = "left"
        case right     = "right"
        case middle    = "middle"
        case wheelUp   = "wheel-up"
        case wheelDown = "wheel-down"
        case side      = "side"
        case extra     = "extra"
    }

    /// 滚轮方向语义糖.
    public enum ScrollDirection: Sendable { case up, down }

    private let socketPath: String
    private let queue = DispatchQueue(label: "hvm.input.forwarder",
                                       qos: .userInitiated)
    private var sockFD: Int32 = -1
    private var connected: Bool = false

    private let viewSizeLock = NSLock()
    private var viewWidth: Double = 1
    private var viewHeight: Double = 1

    /// 上一次发送的归一化绝对坐标. 同点重复不发, 减少 QMP 压力.
    private var lastAbsX: Int32 = -1
    private var lastAbsY: Int32 = -1

    public init(qmpSocketPath: String) {
        self.socketPath = qmpSocketPath
    }

    deinit {
        // 调用方应在 deinit 前显式 disconnect. 这里兜底关 fd 防泄漏,
        // 但不能 dispatch async (queue 持 self 已被释放).
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
    }

    // MARK: - Public

    /// 异步连接 + 完成 QMP 握手. QEMU 子进程 listen socket 通常晚于本类 connect()
    /// 调用 (跟 DisplayChannel 对齐: 50 次 × 100ms 重试, 最多 5 秒). 全部失败后
    /// connected 保持 false, 后续 send 静默丢弃.
    public func connect() {
        queue.async { [weak self] in self?.doConnectWithRetry() }
    }

    public func disconnect() {
        queue.async { [weak self] in self?.forceDisconnect() }
    }

    /// 设置 NSView 当前像素尺寸, 用于鼠标坐标归一化到 0..32767.
    public func setViewSize(width: Double, height: Double) {
        viewSizeLock.lock()
        viewWidth  = max(1, width)
        viewHeight = max(1, height)
        viewSizeLock.unlock()
    }

    public func keyDown(qcode: String) { sendKeyEvent(qcode: qcode, down: true) }
    public func keyUp(qcode: String)   { sendKeyEvent(qcode: qcode, down: false) }

    public func mouseMove(viewX: Double, viewY: Double) {
        guard let abs = absEvents(viewX: viewX, viewY: viewY) else { return }
        enqueue(abs)
    }

    public func mouseButton(_ button: MouseButton, down: Bool,
                            viewX: Double, viewY: Double) {
        var events = absEvents(viewX: viewX, viewY: viewY) ?? []
        events.append([
            "type": "btn",
            "data": ["down": down, "button": button.rawValue],
        ])
        enqueue(events)
    }

    public func scrollWheel(_ direction: ScrollDirection,
                            viewX: Double, viewY: Double) {
        let btn: MouseButton = (direction == .up) ? .wheelUp : .wheelDown
        var events = absEvents(viewX: viewX, viewY: viewY) ?? []
        events.append(["type": "btn",
                       "data": ["down": true,  "button": btn.rawValue]])
        events.append(["type": "btn",
                       "data": ["down": false, "button": btn.rawValue]])
        enqueue(events)
    }

    // MARK: - Event helpers

    private func sendKeyEvent(qcode: String, down: Bool) {
        enqueue([[
            "type": "key",
            "data": [
                "down": down,
                "key": ["type": "qcode", "data": qcode],
            ],
        ]])
    }

    /// 归一化坐标到 0..32767, 重复点返回 nil.
    /// 必须在 queue 之外调用 (用了 viewSizeLock 但访问 lastAbs* 是非线程安全),
    /// 因此 enqueue 在 queue 内做坐标 dedup 太复杂; 简化: lastAbs* 只读 / 写
    /// 都在 queue 外 (UI 主线程), enqueue 之后 queue 真正发送时坐标已固定.
    /// 实际上由于 NSView 回调都在 main thread, 主线程同一线程顺序访问无竞争.
    private func absEvents(viewX: Double, viewY: Double) -> [[String: Any]]? {
        viewSizeLock.lock()
        let w = viewWidth
        let h = viewHeight
        viewSizeLock.unlock()
        let nx = Int32(min(32767, max(0, viewX / w * 32767.0)))
        let ny = Int32(min(32767, max(0, viewY / h * 32767.0)))
        if nx == lastAbsX && ny == lastAbsY { return nil }
        lastAbsX = nx
        lastAbsY = ny
        return [
            ["type": "abs", "data": ["axis": "x", "value": Int(nx)]],
            ["type": "abs", "data": ["axis": "y", "value": Int(ny)]],
        ]
    }

    private func enqueue(_ events: [[String: Any]]) {
        guard !events.isEmpty else { return }
        // 在调用线程 (主线程) 直接 encode 成 Data 后传给 send queue,
        // 避免把 non-Sendable [[String: Any]] 传过 @Sendable closure 边界.
        let cmd: [String: Any] = [
            "execute": "input-send-event",
            "arguments": ["events": events],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cmd) else {
            return
        }
        var buf = data
        buf.append(0x0A) // QMP 是 newline-delimited
        queue.async { [weak self, buf] in
            guard let self = self, self.connected else { return }
            if !self.sendAll(buf) { self.forceDisconnect() }
        }
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

    private func doConnectWithRetry() {
        for attempt in 0..<50 {
            if doConnect() {
                if attempt > 0 {
                    Self.log.info("input QMP connected on attempt \(attempt) socket=\(self.socketPath, privacy: .public)")
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Self.log.error("input QMP connect attempts exhausted (5s) socket=\(self.socketPath, privacy: .public) — keyboard/mouse events will be dropped")
    }

    /// 单次 connect + greeting + qmp_capabilities. true=完成握手 connected=true.
    /// false=任一步失败 (socket 没 listen / EOF / sendAll fail), 调用方负责重试.
    private func doConnect() -> Bool {
        guard sockFD < 0 else { return connected }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: pathLimit) { bp in
                for (i, b) in pathBytes.enumerated() { bp[i] = b }
                bp[pathBytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(fd, sptr,
                                socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { Darwin.close(fd); return false }
        sockFD = fd

        // QMP greeting (单行 JSON), 直接 drain 忽略内容
        if !readJsonLine() { forceDisconnect(); return false }

        // 发 qmp_capabilities, drain return
        guard let negData = try? JSONSerialization.data(
                withJSONObject: ["execute": "qmp_capabilities"]) else {
            forceDisconnect(); return false
        }
        var msg = negData
        msg.append(0x0A)
        if !sendAll(msg) { forceDisconnect(); return false }
        if !readJsonLine() { forceDisconnect(); return false }

        connected = true

        // 后台 drain server 推送的 event / response, 我们都不解析
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.drainServer()
        }
        return true
    }

    /// 读 fd 上的字节, 收到 \n 返回 true. EOF / error 返回 false.
    private func readJsonLine() -> Bool {
        var byte: UInt8 = 0
        while true {
            let r = Darwin.recv(sockFD, &byte, 1, 0)
            if r < 0 {
                if errno == EINTR { continue }
                return false
            }
            if r == 0 { return false }
            if byte == 0x0A { return true }
        }
    }

    private func drainServer() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let cur = sockFD
            if cur < 0 { break }
            let r = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.recv(cur, p.baseAddress, p.count, 0)
            }
            if r <= 0 { break }
        }
        queue.async { [weak self] in self?.forceDisconnect() }
    }

    private func forceDisconnect() {
        connected = false
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
    }
}
