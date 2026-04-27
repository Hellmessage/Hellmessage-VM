// DisplayChannel.swift
//
// HVM-QEMU 显示协议 (HDP) 的 host-side 客户端.
//
// 职责:
//   1. AF_UNIX SOCK_STREAM 连接到 QEMU `-display iosurface,socket=...` 暴露的端点
//   2. 双向 HELLO 协商 (取双方 capability 交集; major 不一致直接断连)
//   3. 后台 read thread 不断收消息, 通过 AsyncStream<Event> 推给上层
//   4. SURFACE_NEW 携带的 SCM_RIGHTS shm fd 在 Event 里直接交给消费者,
//      消费者必须 mmap + close fd 副本 (生命周期约定见 SurfaceArrival 注释)
//   5. 主动 disconnect 发 GOODBYE 后再 close
//
// 协议规范: docs/QEMU_DISPLAY_PROTOCOL.md v1.0.0.
// 三处文件 (本 .swift / hvm_display_proto.h / 协议规范) 必须同步改.

import Foundation
import Darwin
import HVMScmRecv

public final class DisplayChannel: @unchecked Sendable {

    // MARK: - Public types

    public enum Event: @unchecked Sendable {
        /// HELLO 协商完成, 后续可以期望 surface / cursor 等事件.
        case helloDone(negotiatedCapabilities: HDP.Capabilities)
        /// 新 framebuffer (含可 mmap 的 shm fd; 详见 SurfaceArrival).
        case surfaceNew(SurfaceArrival)
        case surfaceDamage(HDP.SurfaceDamage)
        case cursorDefine(HDP.CursorDefine)
        case cursorPos(HDP.CursorPos)
        case ledState(HDP.LedState)
        /// 远端断连或本地主动断开. reason 可能为 nil (网络错误时无 GOODBYE).
        case disconnected(reason: HDP.GoodbyeReason?)
    }

    /// SURFACE_NEW 事件载荷.
    /// **fd 生命周期**: shmFD 由 DisplayChannel 接收, 通过本结构传递给消费者.
    /// 消费者拿到后必须执行 `mmap(...)` 并立即 `close(shmFD)`. 不消费就泄漏.
    public struct SurfaceArrival: @unchecked Sendable {
        public let info: HDP.SurfaceNew
        public let shmFD: Int32
    }

    public enum ConnectError: Error, Sendable {
        case socketCreateFailed(errno: Int32)
        case socketPathTooLong
        case connectFailed(errno: Int32)
        case helloSendFailed
        case helloReceiveFailed
        case versionMismatch(peer: UInt32)
    }

    // MARK: - State

    private let socketPath: String
    private let hostCaps: HDP.Capabilities

    private var sockFD: Int32 = -1
    private let sendQueue = DispatchQueue(label: "hvm.hdp.send",
                                           qos: .userInitiated)
    private var readThread: Thread?
    private var negotiatedCaps: HDP.Capabilities = []

    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>

    public init(socketPath: String,
                hostCapabilities: HDP.Capabilities = .hostAdvertised) {
        self.socketPath = socketPath
        self.hostCaps = hostCapabilities
        var captured: AsyncStream<Event>.Continuation!
        self.events = AsyncStream<Event>(bufferingPolicy: .unbounded) { cont in
            captured = cont
        }
        self.continuation = captured
    }

    deinit {
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
    }

    // MARK: - Public API

    /// 同步建立连接 + 完成 HELLO 协商. 成功返回时 read thread 已启动,
    /// 后续事件通过 `events` 异步到达.
    public func connect() throws {
        try openSocket()
        try sendOurHello()
        let peer = try receivePeerHello()
        try negotiate(peerHello: peer)

        let thr = Thread { [weak self] in self?.readLoop() }
        thr.name = "hvm.hdp.read"
        thr.start()
        readThread = thr
    }

    /// 主动断连. 发 GOODBYE 后 close. 多次调用安全 (idempotent).
    public func disconnect(reason: HDP.GoodbyeReason = .normal) {
        sendGoodbye(reason)
        forceClose()
        continuation.yield(.disconnected(reason: reason))
        continuation.finish()
    }

    /// 请求 guest 调分辨率. 仅在协商阶段拿到 vdagentResize cap 后生效.
    public func requestResize(width: UInt32, height: UInt32) {
        guard negotiatedCaps.contains(.vdagentResize) else { return }
        let req = HDP.ResizeRequest(width: width, height: height)
        let hdr = HDP.Header(type: .resizeRequest, flags: [],
                             payloadLen: UInt32(HDP.ResizeRequest.byteSize))
        let msg = hdr.encode() + req.encode()
        sendQueue.async { [weak self] in
            _ = self?.sendAll(msg)
        }
    }

    // MARK: - Connect helpers

    private func openSocket() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ConnectError.socketCreateFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            throw ConnectError.socketPathTooLong
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
        if rc != 0 {
            let err = errno
            Darwin.close(fd)
            throw ConnectError.connectFailed(errno: err)
        }
        sockFD = fd
    }

    private func sendOurHello() throws {
        let hello = HDP.Hello(protoVersion: HDP.protoVersion,
                              capabilities: hostCaps)
        let hdr = HDP.Header(type: .hello, flags: [],
                             payloadLen: UInt32(HDP.Hello.byteSize))
        let msg = hdr.encode() + hello.encode()
        if !sendAll(msg) {
            forceClose()
            throw ConnectError.helloSendFailed
        }
    }

    private func receivePeerHello() throws -> HDP.Hello {
        let hdr: HDP.Header
        let strayFD: Int32
        do {
            (hdr, strayFD) = try recvHeader()
        } catch {
            forceClose()
            throw ConnectError.helloReceiveFailed
        }
        // HELLO 不应带 fd; 收到也安全关闭, 不报错 (向前兼容)
        if strayFD >= 0 { Darwin.close(strayFD) }
        guard hdr.type == HDP.MessageType.hello.rawValue,
              hdr.payloadLen >= UInt32(HDP.Hello.byteSize) else {
            forceClose()
            throw ConnectError.helloReceiveFailed
        }
        let payload: Data
        do {
            payload = try recvPayload(length: Int(hdr.payloadLen))
        } catch {
            forceClose()
            throw ConnectError.helloReceiveFailed
        }
        guard let hello = HDP.Hello.decode(payload) else {
            forceClose()
            throw ConnectError.helloReceiveFailed
        }
        return hello
    }

    private func negotiate(peerHello: HDP.Hello) throws {
        let peerMajor = HDP.major(of: peerHello.protoVersion)
        if peerMajor != HDP.majorVersion {
            sendGoodbye(.versionMismatch)
            forceClose()
            throw ConnectError.versionMismatch(peer: peerHello.protoVersion)
        }
        negotiatedCaps = peerHello.capabilities.intersection(hostCaps)
        continuation.yield(.helloDone(negotiatedCapabilities: negotiatedCaps))
    }

    // MARK: - Send

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

    private func sendGoodbye(_ reason: HDP.GoodbyeReason) {
        guard sockFD >= 0 else { return }
        let payload = HDP.Goodbye(reason: reason).encode()
        let hdr = HDP.Header(type: .goodbye, flags: [],
                             payloadLen: UInt32(HDP.Goodbye.byteSize))
        let msg = hdr.encode() + payload
        _ = sendAll(msg)
    }

    // MARK: - Recv (used by connect 同线程 + read thread)

    private enum RecvError: Error {
        case eof
        case ioError(errno: Int32)
        case multipleFDs
    }

    /// 收 8 字节 header, **顺带可能附的单个 SCM_RIGHTS fd**.
    /// QEMU 端用 `sendmsg(iov={hdr,payload}, cmsg={fd})` 一次 syscall 把 hdr+payload+fd
    /// 一起发, 所以 fd 跟 header 的字节一同到达接收方 (cmsg 跟 sendmsg 调用绑定,
    /// 第一次 recv 拿到部分字节时一并收 cmsg, 之后再 recv 后续字节不再有 cmsg).
    /// 因此**必须**在 recvHeader 阶段接收 fd, 不能延到 recvPayload.
    private func recvHeader() throws -> (HDP.Header, Int32) {
        var buf = Data(count: HDP.Header.byteSize)
        var fd: Int32 = -1
        try recvIntoBuffer(&buf, length: HDP.Header.byteSize, fdSink: &fd)
        guard let hdr = HDP.Header.decode(buf) else {
            if fd >= 0 { Darwin.close(fd) }
            throw RecvError.ioError(errno: EINVAL)
        }
        return (hdr, fd)
    }

    /// 收 payload only. fd 已在 recvHeader 阶段收完 (见上方注释).
    private func recvPayload(length: Int) throws -> Data {
        if length == 0 { return Data() }
        var buf = Data(count: length)
        try recvIntoBuffer(&buf, length: length, fdSink: nil)
        return buf
    }

    /// 把 length 字节读入 buf, 同时将首个 cmsg fd 写入 fdSink (若提供).
    /// fdSink 已有非负值时再来一个 fd 视为协议错误, 抛 multipleFDs.
    private func recvIntoBuffer(_ buf: inout Data,
                                 length: Int,
                                 fdSink: UnsafeMutablePointer<Int32>?) throws {
        var got = 0
        try buf.withUnsafeMutableBytes { ptr -> Void in
            while got < length {
                var localFD: Int32 = -1
                let n = hvm_scm_recv_msg(sockFD,
                                          ptr.baseAddress!.advanced(by: got),
                                          length - got,
                                          &localFD)
                if n == 0 {
                    if localFD >= 0 { Darwin.close(localFD) }
                    throw RecvError.eof
                }
                if n < 0 {
                    let err = errno
                    if localFD >= 0 { Darwin.close(localFD) }
                    throw RecvError.ioError(errno: err)
                }
                if localFD >= 0 {
                    if let sink = fdSink {
                        if sink.pointee >= 0 {
                            // 多 fd: 关闭新旧两个, 抛
                            Darwin.close(localFD)
                            Darwin.close(sink.pointee)
                            sink.pointee = -1
                            throw RecvError.multipleFDs
                        }
                        sink.pointee = localFD
                    } else {
                        // header 段不应带 fd, 安全起见关掉
                        Darwin.close(localFD)
                    }
                }
                got += Int(n)
            }
        }
    }

    // MARK: - Read loop (background)

    private func readLoop() {
        readLoopBody()
        forceClose()
        continuation.yield(.disconnected(reason: nil))
        continuation.finish()
    }

    private func readLoopBody() {
        while sockFD >= 0 {
            let hdr: HDP.Header
            var fd: Int32 = -1
            do {
                (hdr, fd) = try recvHeader()
            } catch {
                return
            }

            // sanity guard, 跟 ui/iosurface.m 里的 16MB 上限一致
            if hdr.payloadLen > 16 * 1024 * 1024 {
                if fd >= 0 { Darwin.close(fd) }
                return
            }

            var payload = Data()
            if hdr.payloadLen > 0 {
                do {
                    payload = try recvPayload(length: Int(hdr.payloadLen))
                } catch {
                    if fd >= 0 { Darwin.close(fd) }
                    return
                }
            }

            // dispatch 内部消费/关闭 fd.
            if !dispatchMessage(hdr: hdr, payload: payload, attachedFD: fd) {
                return
            }
        }
    }

    /// 返回 false 表示请求关闭连接 (例如收到 GOODBYE).
    private func dispatchMessage(hdr: HDP.Header,
                                  payload: Data,
                                  attachedFD: Int32) -> Bool {
        let dropFD = {
            if attachedFD >= 0 { Darwin.close(attachedFD) }
        }

        guard let type = HDP.MessageType(rawValue: hdr.type) else {
            // 协议规范 §5.4(1): 未知 type 必须 skip 不报错
            dropFD()
            return true
        }

        switch type {
        case .surfaceNew:
            guard let info = HDP.SurfaceNew.decode(payload),
                  attachedFD >= 0 else {
                dropFD()
                return true
            }
            // fd 所有权转移给消费者
            continuation.yield(.surfaceNew(SurfaceArrival(info: info,
                                                            shmFD: attachedFD)))
            return true

        case .surfaceDamage:
            dropFD()
            if let d = HDP.SurfaceDamage.decode(payload) {
                continuation.yield(.surfaceDamage(d))
            }
            return true

        case .cursorDefine:
            dropFD()
            if let c = HDP.CursorDefine.decode(payload) {
                continuation.yield(.cursorDefine(c))
            }
            return true

        case .cursorPos:
            dropFD()
            if let p = HDP.CursorPos.decode(payload) {
                continuation.yield(.cursorPos(p))
            }
            return true

        case .ledState:
            dropFD()
            if let l = HDP.LedState.decode(payload) {
                continuation.yield(.ledState(l))
            }
            return true

        case .goodbye:
            dropFD()
            let reason = HDP.Goodbye.decode(payload).flatMap {
                HDP.GoodbyeReason(rawValue: $0.reason)
            }
            continuation.yield(.disconnected(reason: reason))
            // 让 readLoop 结束: 返回 false
            return false

        case .hello, .resizeRequest:
            // hello 已在 connect 同步段处理; resizeRequest 是 host→QEMU 方向,
            // peer 不该发, 收到时按未识别消息 ignore.
            dropFD()
            return true
        }
    }

    // MARK: - Close

    private func forceClose() {
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
    }
}
