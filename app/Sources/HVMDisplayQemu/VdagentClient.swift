// HVMDisplayQemu/VdagentClient.swift
//
// spice-vdagent client. Host 端通过 QEMU 的 virtio-serial chardev unix socket
// (path=com.redhat.spice.0) 跟 guest 内的 spice-vdagent 服务双向通话.
//
// 当前承载两条业务:
//   1) MONITORS_CONFIG  — host 拖窗口 → 通知 guest 改分辨率
//      (guest 内 spice-vdagent 服务收到 → SetDisplayConfig / xrandr → 改分辨率)
//   2) CLIPBOARD 双向同步 — host ↔ guest 剪贴板桥, UTF-8 文本 (PasteboardBridge 用)
//
// 为啥不接 SPICE GTK:
//   - HVM 主进程不链接 spice-gtk, 也没起 -spice server, 显示走 patch 0002 iosurface
//   - vdagent 协议本身公开且对称, 直接在 Swift 层实现 client 即可
//
// 协议规范 (spice-protocol/spice/vd_agent.h):
//   chunk header (8B): { port: u32 = VDP_CLIENT_PORT(1), size: u32 }
//   message header (20B): { protocol: u32=1, type: u32, opaque: u64=0, size: u32 }
//   data 视 type 而定. 已实现的 type:
//     - VD_AGENT_MONITORS_CONFIG (2)        — 改分辨率
//     - VD_AGENT_ANNOUNCE_CAPABILITIES (6)  — caps 协商 (启动握手必发)
//     - VD_AGENT_CLIPBOARD_GRAB (7)         — "我有这些 mime 类型"
//     - VD_AGENT_CLIPBOARD_REQUEST (8)      — "把那个 mime 内容发我"
//     - VD_AGENT_CLIPBOARD (4)              — 实际数据
//     - VD_AGENT_CLIPBOARD_RELEASE (9)      — "我的剪贴板没了"
//
// 协商 caps:
//   CLIPBOARD_BY_DEMAND (5) + CLIPBOARD_SELECTION (6).
//   不协商基础 CLIPBOARD (3) — 那条是无 GRAB/REQUEST 的 push, 跟我们 pull 模式冲突.
//
// 失败策略:
//   - socket / write 错误 silently swallow + log.warn — vdagent 通道挂了不能阻塞
//     主路径 (拖窗口 / 剪贴板)
//   - 已 connect 后 read loop 收到 EOF / read 错误 → close + lazy 重连等下次 send

import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "Vdagent")

public final class VdagentClient: @unchecked Sendable {

    // MARK: - 协议常量

    private static let VDP_CLIENT_PORT: UInt32 = 1
    private static let VD_AGENT_PROTOCOL: UInt32 = 1

    // 消息 type
    private static let VD_AGENT_CLIPBOARD: UInt32                = 4
    private static let VD_AGENT_MONITORS_CONFIG: UInt32          = 2
    private static let VD_AGENT_ANNOUNCE_CAPABILITIES: UInt32    = 6
    private static let VD_AGENT_CLIPBOARD_GRAB: UInt32           = 7
    private static let VD_AGENT_CLIPBOARD_REQUEST: UInt32        = 8
    private static let VD_AGENT_CLIPBOARD_RELEASE: UInt32        = 9

    // capabilities 位编号 (见 vd_agent.h enum VDAgentCap)
    private static let VD_AGENT_CAP_CLIPBOARD_BY_DEMAND: UInt32  = 5
    private static let VD_AGENT_CAP_CLIPBOARD_SELECTION: UInt32  = 6

    // selection 编号 (CLIPBOARD = 通用剪贴板, Win/Mac 唯一; PRIMARY/SECONDARY 是 X11 概念)
    private static let SELECTION_CLIPBOARD: UInt8 = 0

    // mime type 编号
    private static let MIME_NONE: UInt32       = 0
    private static let MIME_UTF8_TEXT: UInt32  = 1

    // MARK: - 状态

    private let socketPath: String
    private let queue = DispatchQueue(label: "hvm.vdagent.client", qos: .userInitiated)
    private var sockFD: Int32 = -1
    private var readThread: Thread?

    /// 上次发送的 MonitorsConfig (用于 dedup, 同尺寸不重复发).
    private var lastSentSize: (width: UInt32, height: UInt32)?

    /// 远端宣告的 caps. nil 表示还没握手成功. read loop 收到 ANNOUNCE_CAPABILITIES 时填入.
    private var remoteCaps: UInt32 = 0
    private var capsNegotiated = false

    /// useSelectionPrefix: spice 协议要求双方都 advertise CAP_CLIPBOARD_SELECTION 时,
    /// GRAB/REQUEST/CLIPBOARD/RELEASE 数据带 1 byte selection + 3 byte pad 前缀.
    /// host 永远 advertise (sendCapabilitiesLocked 写死), 实际是否启用看 remoteCaps.
    ///
    /// 实测 UTM Guest Tools 的 vdagent.exe (Win 版): caps=0x46B7, bit 6 (SELECTION) 缺,
    /// 它发的 GRAB 数据 = 4 bytes (单 mime, 无 prefix). 严格按 cap 协商即可.
    private var useSelectionPrefix: Bool {
        return (remoteCaps & (UInt32(1) << VdagentClient.VD_AGENT_CAP_CLIPBOARD_SELECTION)) != 0
    }

    // MARK: - 公共回调

    /// guest 通过 GRAB 通知 host "我有 UTF-8 文本", host 回 REQUEST 后 guest 发 CLIPBOARD,
    /// 整个流程结束后这个 callback 被调一次. 在内部 queue 上调; 调用者负责切到目标线程.
    public var onClipboardTextReceived: ((String) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if sockFD >= 0 {
            Darwin.close(sockFD); sockFD = -1
        }
    }

    // MARK: - 公共 API

    /// 异步 connect vdagent socket + 启动 read loop + 发握手 ANNOUNCE_CAPABILITIES.
    /// 失败 silently, 后续 send 静默丢弃.
    public func connect() {
        queue.async { [weak self] in self?.doConnect() }
    }

    public func disconnect() {
        queue.async { [weak self] in self?.doDisconnect() }
    }

    /// 发 VDAgentMonitorsConfig 给 guest spice-vdagent. 单显示器, 32-bit color, 原点 0,0.
    /// dedup: 跟上次相同尺寸不重发, 避免 user 抖动鼠标边缘连续触发.
    public func sendMonitorsConfig(width: UInt32, height: UInt32) {
        queue.async { [weak self] in
            guard let self else { return }
            if let last = self.lastSentSize, last.width == width, last.height == height {
                return
            }
            self.lastSentSize = (width, height)
            self.ensureConnectedLocked()
            guard self.sockFD >= 0 else {
                log.warning("vdagent send dropped: not connected (\(width)x\(height))")
                return
            }

            // VDAgentMonConfig (20B): height, width, depth, x, y
            var monBuf = Data(capacity: 20)
            VdagentClient.appendU32(height, to: &monBuf)
            VdagentClient.appendU32(width, to: &monBuf)
            VdagentClient.appendU32(32, to: &monBuf)
            VdagentClient.appendI32(0, to: &monBuf)
            VdagentClient.appendI32(0, to: &monBuf)

            // VDAgentMonitorsConfig (8B): num_of_monitors, flags
            var cfgBuf = Data(capacity: 8 + monBuf.count)
            VdagentClient.appendU32(1, to: &cfgBuf)
            VdagentClient.appendU32(0, to: &cfgBuf)
            cfgBuf.append(monBuf)

            self.sendMessageLocked(type: VdagentClient.VD_AGENT_MONITORS_CONFIG, payload: cfgBuf)
            log.info("vdagent MONITORS_CONFIG sent \(width)x\(height) → fd=\(self.sockFD)")
        }
    }

    /// host pasteboard 变化时调: GRAB → 等 guest REQUEST → 发 CLIPBOARD 数据.
    /// 实现简化: 我们直接同时把 GRAB + DATA 缓存在 client 内, 收 REQUEST 时翻出.
    /// 没收 REQUEST 也不重发 (每次新内容覆盖旧的).
    public func sendClipboardText(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingHostText = text
            self.ensureConnectedLocked()
            guard self.sockFD >= 0, self.capsNegotiated else {
                log.info("vdagent clipboard GRAB pending (caps not negotiated yet)")
                return
            }
            self.sendGrabLocked()
        }
    }

    /// host 端剪贴板被清空 / 离场: 通知 guest 释放它持有的 host 端 mirror.
    /// useSelectionPrefix=true 时数据 = selection+pad (4B); false 时空 body.
    public func sendClipboardRelease() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingHostText = nil
            guard self.sockFD >= 0, self.capsNegotiated else { return }
            var body = Data()
            if self.useSelectionPrefix {
                body.append(VdagentClient.SELECTION_CLIPBOARD)
                body.append(0); body.append(0); body.append(0)
            }
            self.sendMessageLocked(type: VdagentClient.VD_AGENT_CLIPBOARD_RELEASE, payload: body)
        }
    }

    /// 仅 queue 内访问: host 这边正在持有 (尚未发送 / 等 guest REQUEST) 的 UTF-8 文本.
    private var pendingHostText: String?

    // MARK: - 内部: connect / disconnect

    private func doConnect() {
        guard sockFD < 0 else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.warning("vdagent socket() failed errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            log.warning("vdagent socket path 太长: \(self.socketPath)")
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
            log.warning("vdagent connect errno=\(saved) path=\(self.socketPath)")
            return
        }
        sockFD = fd
        log.info("vdagent connected to \(self.socketPath)")

        // 启 read loop (跑独立线程 blocking read; 不占 dispatch queue, 收到消息再回 queue 处理)
        let t = Thread { [weak self] in self?.runReadLoop() }
        t.name = "hvm.vdagent.read"
        readThread = t
        t.start()

        // 主动握手 — 即便 guest vdagent 还没起来, QEMU chardev 是 server, 写入会 buffer
        // 等 guest 连上时 flush. caps_negotiated 仍由收到对端的 ANNOUNCE 触发置 true.
        sendCapabilitiesLocked(request: 1)
    }

    private func doDisconnect() {
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
        readThread = nil
        lastSentSize = nil
        capsNegotiated = false
        remoteCaps = 0
        pendingHostText = nil
    }

    /// queue 内调用: 没连或断了就 lazy 重连一次.
    private func ensureConnectedLocked() {
        if sockFD < 0 { doConnect() }
    }

    // MARK: - 内部: 写消息

    /// queue 内调用. 构造 chunk + message header 后整包写出.
    /// 失败 → close + 下次 lazy 重连.
    private func sendMessageLocked(type: UInt32, payload: Data) {
        var msgBuf = Data(capacity: 20 + payload.count)
        VdagentClient.appendU32(VdagentClient.VD_AGENT_PROTOCOL, to: &msgBuf)
        VdagentClient.appendU32(type, to: &msgBuf)
        VdagentClient.appendU64(0, to: &msgBuf)
        VdagentClient.appendU32(UInt32(payload.count), to: &msgBuf)
        msgBuf.append(payload)

        var chunkBuf = Data(capacity: 8 + msgBuf.count)
        VdagentClient.appendU32(VdagentClient.VDP_CLIENT_PORT, to: &chunkBuf)
        VdagentClient.appendU32(UInt32(msgBuf.count), to: &chunkBuf)
        chunkBuf.append(msgBuf)

        if !sendAll(chunkBuf) {
            log.warning("vdagent send type=\(type) failed errno=\(errno), 关连接等下次 lazy 重连")
            // 关 socket 让 read loop 自然退出; 下次 send 触发 lazy 重连
            if sockFD >= 0 { Darwin.close(sockFD); sockFD = -1 }
            capsNegotiated = false
        }
    }

    private func sendCapabilitiesLocked(request: UInt32) {
        let caps: UInt32 = (UInt32(1) << VdagentClient.VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)
                         | (UInt32(1) << VdagentClient.VD_AGENT_CAP_CLIPBOARD_SELECTION)
        var body = Data(capacity: 8)
        VdagentClient.appendU32(request, to: &body)
        VdagentClient.appendU32(caps, to: &body)
        sendMessageLocked(type: VdagentClient.VD_AGENT_ANNOUNCE_CAPABILITIES, payload: body)
        log.info("vdagent ANNOUNCE_CAPABILITIES sent caps=0x\(String(caps, radix: 16), privacy: .public) request=\(request, privacy: .public)")
    }

    /// queue 内调用. 发 GRAB 声明 host 端有 UTF-8 文本.
    /// useSelectionPrefix=true 数据布局: selection(1B) + pad(3B) + N × uint32 mime types
    /// useSelectionPrefix=false 直接: N × uint32 mime types (Win 版 vdagent 走这条)
    private func sendGrabLocked() {
        var body = Data()
        if useSelectionPrefix {
            body.append(VdagentClient.SELECTION_CLIPBOARD)
            body.append(0); body.append(0); body.append(0)
        }
        VdagentClient.appendU32(VdagentClient.MIME_UTF8_TEXT, to: &body)
        sendMessageLocked(type: VdagentClient.VD_AGENT_CLIPBOARD_GRAB, payload: body)
        log.info("vdagent CLIPBOARD_GRAB sent (mime=utf8, selPrefix=\(self.useSelectionPrefix, privacy: .public))")
    }

    /// queue 内调用. 发 REQUEST 让 guest 发剪贴板内容过来.
    /// useSelectionPrefix=true 时多 selection+pad 前缀; false 时直接 mime.
    private func sendRequestLocked(mime: UInt32, selection: UInt8 = SELECTION_CLIPBOARD) {
        var body = Data()
        if useSelectionPrefix {
            body.append(selection)
            body.append(0); body.append(0); body.append(0)
        }
        VdagentClient.appendU32(mime, to: &body)
        sendMessageLocked(type: VdagentClient.VD_AGENT_CLIPBOARD_REQUEST, payload: body)
        log.info("vdagent CLIPBOARD_REQUEST sent sel=\(selection, privacy: .public) mime=\(mime, privacy: .public) selPrefix=\(self.useSelectionPrefix, privacy: .public)")
    }

    /// queue 内调用. 发 CLIPBOARD 数据 (UTF-8 文本) 应答 guest 的 REQUEST.
    private func sendClipboardDataLocked(text: String, selection: UInt8 = SELECTION_CLIPBOARD) {
        let utf8 = Array(text.utf8)
        var body = Data()
        if useSelectionPrefix {
            body.append(selection)
            body.append(0); body.append(0); body.append(0)
        }
        VdagentClient.appendU32(VdagentClient.MIME_UTF8_TEXT, to: &body)
        body.append(contentsOf: utf8)
        sendMessageLocked(type: VdagentClient.VD_AGENT_CLIPBOARD, payload: body)
        log.info("vdagent CLIPBOARD data sent sel=\(selection, privacy: .public) (\(utf8.count, privacy: .public) bytes utf8) selPrefix=\(self.useSelectionPrefix, privacy: .public)")
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

    // MARK: - 内部: read loop + 解析

    private func runReadLoop() {
        let fd = sockFD  // snapshot — 断开后 fd 会被关闭, read 立即返 0/-1 退出
        guard fd >= 0 else { return }

        // chunk-reassembly state machine (readThread own, 不跨线程).
        // spice vdagent 协议: 长 message 分多 chunk 发送.
        //   - 第一 chunk 的 body = VDAgentMessage header (20B) + 部分 data
        //   - 后续 chunk 的 body = 继续 data (no message header)
        //   - 每个 chunk 独立有 chunk header (port(4) + size(4))
        //   - 通过 message header.size 字段总长判定何时拼完
        var rolling = Data()
        var inMessage = false
        var curMsgType: UInt32 = 0
        var curMsgTotalSize: Int = 0
        var curMsgBuffer = Data()
        let recvBufSize = 8192
        var recvBuf = [UInt8](repeating: 0, count: recvBufSize)

        // chunk-by-chunk 解析, 返回解析掉的字节数; 不完整返 nil
        func tryConsumeOneChunk() -> Bool {
            guard rolling.count >= 8 else { return false }
            let _port = readU32(rolling, 0); _ = _port
            let chunkBodySize = Int(readU32(rolling, 4))
            guard rolling.count >= 8 + chunkBodySize else { return false }
            let chunkBody = rolling.subdata(in: 8..<(8 + chunkBodySize))
            rolling.removeSubrange(0..<(8 + chunkBodySize))

            if !inMessage {
                // 第一 chunk: 20B message header + 部分 data
                guard chunkBody.count >= 20 else {
                    log.warning("vdagent first chunk too small for VDAgentMessage header: \(chunkBody.count)")
                    return true
                }
                let _proto = readU32(chunkBody, 0); _ = _proto
                let type   = readU32(chunkBody, 4)
                let _opaq  = readU64(chunkBody, 8); _ = _opaq
                let pLen   = Int(readU32(chunkBody, 16))
                let firstData = chunkBody.subdata(in: 20..<chunkBody.count)
                inMessage = true
                curMsgType = type
                curMsgTotalSize = pLen
                curMsgBuffer = firstData
            } else {
                // 后续 chunk: 直接累加 data
                curMsgBuffer.append(chunkBody)
            }

            // 完整 message?
            if curMsgBuffer.count >= curMsgTotalSize {
                let payload = curMsgBuffer.prefix(curMsgTotalSize)
                let typeSnap = curMsgType
                let payloadSnap = Data(payload)
                queue.async { [weak self] in
                    self?.handleIncoming(type: typeSnap, payload: payloadSnap)
                }
                inMessage = false
                curMsgType = 0
                curMsgTotalSize = 0
                curMsgBuffer = Data()
            }
            return true
        }

        while true {
            let n = recvBuf.withUnsafeMutableBufferPointer { bp in
                Darwin.recv(fd, bp.baseAddress!, recvBufSize, 0)
            }
            if n == 0 {
                log.info("vdagent read loop EOF (guest 端关了 / chardev reset)")
                queue.async { [weak self] in self?.doDisconnect() }
                return
            }
            if n < 0 {
                if errno == EINTR { continue }
                log.warning("vdagent read errno=\(errno), 退出 read loop")
                queue.async { [weak self] in self?.doDisconnect() }
                return
            }
            rolling.append(recvBuf, count: n)
            while tryConsumeOneChunk() {}
        }
    }

    /// queue 内调用. 按 type 分派.
    private func handleIncoming(type: UInt32, payload: Data) {
        switch type {
        case VdagentClient.VD_AGENT_ANNOUNCE_CAPABILITIES:
            handleAnnounceCapsLocked(payload)
        case VdagentClient.VD_AGENT_CLIPBOARD_GRAB:
            handleGuestGrabLocked(payload)
        case VdagentClient.VD_AGENT_CLIPBOARD_REQUEST:
            handleGuestRequestLocked(payload)
        case VdagentClient.VD_AGENT_CLIPBOARD:
            handleGuestClipboardLocked(payload)
        case VdagentClient.VD_AGENT_CLIPBOARD_RELEASE:
            log.info("vdagent CLIPBOARD_RELEASE from guest")
        default:
            // MOUSE_STATE / DISPLAY_CONFIG / etc. — 不处理
            break
        }
    }

    private func handleAnnounceCapsLocked(_ payload: Data) {
        // VDAgentAnnounceCapabilities: request(4) + caps[N](4 × N)
        guard payload.count >= 8 else {
            log.warning("vdagent ANNOUNCE_CAPABILITIES payload 太短 \(payload.count)")
            return
        }
        let request = readU32(payload, 0)
        let caps = readU32(payload, 4)
        remoteCaps = caps
        capsNegotiated = true
        log.info("vdagent guest caps=0x\(String(caps, radix: 16), privacy: .public) request=\(request, privacy: .public) selPrefix=\(self.useSelectionPrefix, privacy: .public)")
        // spice 协议规定: 收到 request=1 的 ANNOUNCE 必须回 ANNOUNCE with request=0,
        // 否则对端 (guest spice-vdagent) 视为握手未完成, 拒收 GRAB/REQUEST/CLIPBOARD.
        // 之前 doConnect 主动发过 (with request=1) 是 host 端 initiator; 但 guest 可能
        // 在我们 send 之前已经发过自己的 ANNOUNCE, 我们也必须回应它的 request=1.
        // 用 request=0 防 ping-pong 死循环 (对端收到 request=0 不再回, 链路收敛).
        if request == 1 {
            sendCapabilitiesLocked(request: 0)
        }
        // 若 host 已经有 pendingHostText, 现在 caps 协商完了可以补发 GRAB
        if pendingHostText != nil {
            sendGrabLocked()
        }
    }

    /// guest 那边复制了东西, 通知我们 mime 类型. 我们如果支持就发 REQUEST.
    /// useSelectionPrefix 决定数据布局: with → selection(1)+pad(3)+N*mime(4); without → N*mime(4).
    private func handleGuestGrabLocked(_ payload: Data) {
        let (selection, mimeOff) = parseSelectionPrefix(payload)
        guard payload.count >= mimeOff + 4 else {
            log.warning("vdagent GRAB payload 太短 \(payload.count, privacy: .public)")
            return
        }
        // 扫所有 mime, 找 UTF8_TEXT 优先
        var off = mimeOff
        var foundMime: UInt32? = nil
        while off + 4 <= payload.count {
            let mime = readU32(payload, off)
            if mime == VdagentClient.MIME_UTF8_TEXT {
                foundMime = mime
                break
            }
            off += 4
        }
        guard let mime = foundMime else {
            log.info("vdagent guest GRAB sel=\(selection, privacy: .public) 无 UTF8_TEXT mime, 跳过")
            return
        }
        log.info("vdagent guest GRAB sel=\(selection, privacy: .public) mime=\(mime, privacy: .public), 发 REQUEST")
        sendRequestLocked(mime: mime, selection: selection)
    }

    /// guest 发 REQUEST 要 host 端剪贴板内容.
    private func handleGuestRequestLocked(_ payload: Data) {
        let (selection, mimeOff) = parseSelectionPrefix(payload)
        guard payload.count >= mimeOff + 4 else {
            log.warning("vdagent REQUEST payload 太短 \(payload.count, privacy: .public)")
            return
        }
        let mime = readU32(payload, mimeOff)
        guard mime == VdagentClient.MIME_UTF8_TEXT else {
            log.info("vdagent guest REQUEST 非 UTF8_TEXT (mime=\(mime, privacy: .public), sel=\(selection, privacy: .public)), 跳过")
            return
        }
        guard let text = pendingHostText else {
            log.info("vdagent guest REQUEST sel=\(selection, privacy: .public) 但 host pending 为空, 跳过")
            return
        }
        log.info("vdagent guest REQUEST sel=\(selection, privacy: .public) mime=\(mime, privacy: .public), 发 CLIPBOARD (\(text.utf8.count, privacy: .public) bytes)")
        sendClipboardDataLocked(text: text, selection: selection)
    }

    /// guest 真发数据过来了 (host 先 REQUEST 触发, 或 guest 主动 GRAB 后 host REQUEST 的回应).
    private func handleGuestClipboardLocked(_ payload: Data) {
        let (selection, mimeOff) = parseSelectionPrefix(payload)
        guard payload.count >= mimeOff + 4 else {
            log.warning("vdagent CLIPBOARD payload 太短 \(payload.count, privacy: .public)")
            return
        }
        let mime = readU32(payload, mimeOff)
        guard mime == VdagentClient.MIME_UTF8_TEXT else {
            log.info("vdagent guest CLIPBOARD 非 UTF8 (mime=\(mime, privacy: .public), sel=\(selection, privacy: .public)), 跳过")
            return
        }
        let dataStart = payload.startIndex + mimeOff + 4
        let textBytes = payload.subdata(in: dataStart..<payload.endIndex)
        guard let text = String(data: textBytes, encoding: .utf8) else {
            log.warning("vdagent guest CLIPBOARD UTF-8 解码失败, \(textBytes.count, privacy: .public) bytes (sel=\(selection, privacy: .public))")
            return
        }
        log.info("vdagent CLIPBOARD recv from guest sel=\(selection, privacy: .public) (\(textBytes.count, privacy: .public) bytes)")
        onClipboardTextReceived?(text)
    }

    /// 按 useSelectionPrefix 解析 payload 头. 返回 (selection, mime 起始 offset).
    /// 没有 selection prefix 时, selection 默认 0 (CLIPBOARD), mime offset = 0.
    /// **兼容性**: 即便协商 useSelectionPrefix=true, 仍允许对端发不带 prefix 的短消息
    /// (UTM Win vdagent 即便 host advertise SELECTION 它自己也不带 prefix). 通过 payload
    /// 长度推断: 无 prefix 时 payload 是 N*4 (mime entries) 或 0+data; 带 prefix 时 4+...
    private func parseSelectionPrefix(_ payload: Data) -> (UInt8, Int) {
        // 严格无 prefix: 直接 mime 起始
        if !useSelectionPrefix { return (VdagentClient.SELECTION_CLIPBOARD, 0) }
        // 协商有 prefix 但 payload 太短不够 4 字节前缀, 兜底当无 prefix
        guard payload.count >= 4 else { return (VdagentClient.SELECTION_CLIPBOARD, 0) }
        let sel = payload[payload.startIndex]
        return (sel, 4)
    }

    // MARK: - little-endian appender / reader

    private static func appendU32(_ v: UInt32, to buf: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
    }

    private static func appendI32(_ v: Int32, to buf: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
    }

    private static func appendU64(_ v: UInt64, to buf: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return data.withUnsafeBytes { raw -> UInt32 in
            var v: UInt32 = 0
            memcpy(&v, raw.baseAddress!.advanced(by: s), 4)
            return UInt32(littleEndian: v)
        }
    }

    private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        let s = data.startIndex + offset
        return data.withUnsafeBytes { raw -> UInt64 in
            var v: UInt64 = 0
            memcpy(&v, raw.baseAddress!.advanced(by: s), 8)
            return UInt64(littleEndian: v)
        }
    }
}
