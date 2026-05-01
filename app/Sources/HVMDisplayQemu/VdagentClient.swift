// HVMDisplayQemu/VdagentClient.swift
//
// **DEPRECATED** — 已被 SpiceMainClient.swift 替换. 文件保留作 raw chardev 模式参考.
//
// 历史: 这是 commit f94d45e 时实现的 raw `-chardev socket,server=on` 模式 vdagent client,
// 走裸 chardev 直接连 unix socket 发 VDAgentMessage. 实测 vdservice 在 raw 模式下 reply
// error=1 GENERIC, 不会 forward MONITORS_CONFIG 给 user-session vdagent.exe → 分辨率不变.
//
// 替代方案: SpiceMainClient 走 SPICE main channel + `-chardev spicevmc,name=vdagent`,
// spice-server 中转走「正常 SPICE 通路」, vdservice 接受并 forward 给 vdagent.exe → 分辨率改成功.
//
// 为何保留: 如果未来上游 spice-vdagent 修了 raw 模式 forward 行为, 或者要在不引 spice-server
// 的轻量构建里跑, 这条裸通路有参考价值. 当前不被 wire up, 任何 instantiate 都是错.
//
// ---- 以下原文档保留, 请同时阅读 SpiceMainClient.swift ----
//
// spice-vdagent client. Host 端通过 QEMU 的 virtio-serial chardev unix socket
// (path=com.redhat.spice.0) 给 guest 内的 spice-vdagent 服务发 VDAgentMonitorsConfig
// 消息, 让 guest 调 Win API SetDisplayConfig 改分辨率, 实现拖 HVM 主窗口动态 resize.
//
// 为啥需要这条路径:
//   - patch 0002 的 iosurface display backend 收到 client RESIZE_REQUEST 后调
//     dpy_set_ui_info, 但这只更新 QEMU 内部 UI 状态, **不会** emit 到 vdagent chardev.
//     vdagent chardev 是 spice 协议通道, 上层得有 spice client 才能翻译 dpy_ui_info →
//     VDAgentMonitorsConfig → vdagent chardev → guest spice-vdagent → Win API.
//   - hvm-mac 没用 -spice (走自家 patch 0002 iosurface), 所以没 spice client.
//     这里在 Swift 端补一个轻量 vdagent client, 直接 connect chardev socket
//     发 binary VDAgentMonitorsConfig 消息.
//
// 协议规范 (spice-protocol/spice/vd_agent.h):
//   chunk header (8B): { port: u32 = VDP_CLIENT_PORT(1), size: u32 = VDAgentMessage 全长 }
//   message header (20B): { protocol: u32=1, type: u32, opaque: u64=0, size: u32 = data 长 }
//   data 视 type 而定. ANNOUNCE_CAPABILITIES 数据:
//     VDAgentAnnounceCapabilities (8B): { request: u32, caps[0]: u32 (bitmask) }
//   MONITORS_CONFIG 数据:
//     VDAgentMonitorsConfig (8B): { num_of_monitors: u32, flags: u32 }
//     VDAgentMonConfig (20B) × N: { height, width, depth, x, y } — 全 u32/i32
//   单显示器 + 1 个 MonConfig = 8+20 = 28B; 整 message = 20+28 = 48B; 整 chunk = 8+48 = 56B.
//
// 协议握手 (关键, hvm-mac WIP commit f4e3e69 漏了这一步导致 Win 收 MONITORS_CONFIG 丢弃):
//   spice-vdagent.exe 在 guest 内 receive MONITORS_CONFIG 时, 会先 check
//     client_caps & (1 << VD_AGENT_CAP_MONITORS_CONFIG)
//   只有 client 之前发过 ANNOUNCE_CAPABILITIES 声明这个 cap, 才会接受 MONITORS_CONFIG.
//   UTM/spice-server 自动做这个握手 (-chardev spicevmc 走 SPICE main channel),
//   HVM 走裸 -chardev socket 没 SPICE server 中介, **必须 client 自己发**.
//
// 我们 connect 成功后立刻发 ANNOUNCE_CAPABILITIES 一次 (request=1, caps=MONITORS_CONFIG),
// 之后 sendMonitorsConfig 才会被 guest 接受. 同时起 read-drain 把 agent 端发过来的
// 字节 (它的 ANNOUNCE_CAPABILITIES reply 等) 读掉丢弃, 防 socket recv buffer 涨满.
//
// 失败策略: 任何 socket / write 错误 silently swallow + log.warn — vdagent 通道挂了
// 不能阻塞 user 拖窗口 / 让画面卡死, 老 framebuffer 仍能渲染.

import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "Vdagent")

@available(*, deprecated, message: "raw -chardev socket 模式 vdservice 不 forward 给 vdagent.exe; 改用 SpiceMainClient (走 SPICE main channel + spicevmc multiplex)")
public final class VdagentClient: @unchecked Sendable {

    // VD_AGENT 协议常量 (跟 spice-protocol/spice/vd_agent.h 同步)
    private static let VDP_CLIENT_PORT: UInt32 = 1
    private static let VD_AGENT_PROTOCOL: UInt32 = 1
    // VDAgentMessage type enum (vd_agent.h):
    // 1=MOUSE_STATE 2=MONITORS_CONFIG 3=REPLY 4=CLIPBOARD 5=DISPLAY_CONFIG 6=ANNOUNCE_CAPABILITIES
    private static let VD_AGENT_MOUSE_STATE: UInt32 = 1
    private static let VD_AGENT_MONITORS_CONFIG: UInt32 = 2
    private static let VD_AGENT_REPLY: UInt32 = 3
    private static let VD_AGENT_ANNOUNCE_CAPABILITIES: UInt32 = 6
    /// VD_AGENT_CAP_MONITORS_CONFIG = 1 (bit position, 详见 vd_agent.h enum {VDAgentCap})
    private static let VD_AGENT_CAP_MONITORS_CONFIG_BIT: UInt32 = 1

    private let socketPath: String
    private let queue = DispatchQueue(label: "hvm.vdagent.client", qos: .userInitiated)
    private var sockFD: Int32 = -1
    /// 是否已经发过 ANNOUNCE_CAPABILITIES (每次 connect 后只发一次).
    private var capsAnnounced: Bool = false
    /// 上次发送的 MonitorsConfig (用于 dedup, 同尺寸不重复发).
    private var lastSentSize: (width: UInt32, height: UInt32)?
    /// agent 端往回发字节的 read drain (DispatchSourceRead). 仅消费丢弃, 不解析.
    private var readSource: DispatchSourceRead?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if sockFD >= 0 {
            Darwin.close(sockFD); sockFD = -1
        }
    }

    /// 异步 connect vdagent socket. 失败 silently, 后续 send 静默丢弃.
    /// 重连支持: 已连断了再调 connect 会重新连.
    public func connect() {
        queue.async { [weak self] in self?.doConnect() }
    }

    public func disconnect() {
        queue.async { [weak self] in self?.doDisconnect() }
    }

    /// 发 VDAgentMonitorsConfig 给 guest spice-vdagent. 单显示器, 32-bit color, 原点 0,0.
    /// dedup: 跟上次相同尺寸不重发, 避免 user 抖动鼠标边缘连续触发.
    /// 所有 socket / write 错误 silently swallow, 不抛.
    ///
    /// 协议握手 timing 关键: connect() 发生在 QEMU 启动时, guest 内 spice-vdagent.exe
    /// 服务尚未启动 → virtio-serial port 的 guest_connected=false → QEMU 直接 drop 我们
    /// 写入 chardev 的字节. 等用户拖窗口时, guest 桌面已起 + service 在跑, 这时才是
    /// ANNOUNCE 真正能送达的时机. 所以**每次 sendMonitorsConfig 调用前都重发一次
    /// ANNOUNCE_CAPABILITIES**, 不依赖 connect 时发的那次. 36 字节开销, dedup 自然
    /// 防 spam (同尺寸不进这条路径).
    public func sendMonitorsConfig(width: UInt32, height: UInt32) {
        queue.async { [weak self] in
            guard let self else { return }
            // dedup
            if let last = self.lastSentSize, last.width == width, last.height == height {
                return
            }
            self.lastSentSize = (width, height)
            // 没连先尝试 connect (lazy + auto-recovery)
            if self.sockFD < 0 {
                self.doConnect()
            }
            guard self.sockFD >= 0 else {
                log.warning("vdagent send dropped: not connected (\(width)x\(height))")
                return
            }
            // 每次都重发 ANNOUNCE_CAPABILITIES (boot 期 connect 时发的会被 virtio-serial
            // 丢弃, 必须在 guest service ready 后再发一次; 这里是 user 拖窗口触发, timing 对)
            if !self.sendAnnounceCapabilities() {
                log.warning("vdagent ANNOUNCE_CAPABILITIES 重发失败, 关连接")
                self.doDisconnect()
                return
            }

            // 构造 VDAgentMonConfig (20B)
            var monBuf = Data(capacity: 20)
            VdagentClient.appendU32(height, to: &monBuf)
            VdagentClient.appendU32(width, to: &monBuf)
            VdagentClient.appendU32(32, to: &monBuf)         // depth bits
            VdagentClient.appendI32(0, to: &monBuf)          // x
            VdagentClient.appendI32(0, to: &monBuf)          // y

            // VDAgentMonitorsConfig header (8B) + 1 个 MonConfig
            var cfgBuf = Data(capacity: 8 + monBuf.count)
            VdagentClient.appendU32(1, to: &cfgBuf)          // num_of_monitors
            VdagentClient.appendU32(0, to: &cfgBuf)          // flags
            cfgBuf.append(monBuf)

            // VDAgentMessage header (20B) + payload (cfgBuf)
            var msgBuf = Data(capacity: 20 + cfgBuf.count)
            VdagentClient.appendU32(VdagentClient.VD_AGENT_PROTOCOL, to: &msgBuf)
            VdagentClient.appendU32(VdagentClient.VD_AGENT_MONITORS_CONFIG, to: &msgBuf)
            VdagentClient.appendU64(0, to: &msgBuf)          // opaque
            VdagentClient.appendU32(UInt32(cfgBuf.count), to: &msgBuf)
            msgBuf.append(cfgBuf)

            // VDIChunkHeader (8B) + VDAgentMessage frame
            var chunkBuf = Data(capacity: 8 + msgBuf.count)
            VdagentClient.appendU32(VdagentClient.VDP_CLIENT_PORT, to: &chunkBuf)
            VdagentClient.appendU32(UInt32(msgBuf.count), to: &chunkBuf)
            chunkBuf.append(msgBuf)

            // 写 socket. 短写 / 错误 → close, 下次 send 时 lazy 重连.
            if !self.sendAll(chunkBuf) {
                log.warning("vdagent send failed (\(width)x\(height)), 关连接等下次 lazy 重连")
                self.doDisconnect()
            } else {
                log.info("vdagent MONITORS_CONFIG sent \(width)x\(height) (\(chunkBuf.count) bytes)")
            }
        }
    }

    // MARK: - 内部

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

        // 紧接发 VD_AGENT_ANNOUNCE_CAPABILITIES 握手, 否则 guest 内 spice-vdagent.exe
        // 收 MONITORS_CONFIG 时 client_caps & VD_AGENT_CAP_MONITORS_CONFIG = 0 直接丢弃.
        // request=1: 请对端 (guest agent) 也回 announce; 我们不需要解析它, 起 read-drain
        // 把回包字节读掉丢弃即可 (防 socket recv buffer 涨满阻塞 agent 端 write).
        if !self.sendAnnounceCapabilities() {
            log.warning("vdagent ANNOUNCE_CAPABILITIES 发送失败, 关连接等下次 lazy 重连")
            self.doDisconnect()
            return
        }
        self.capsAnnounced = true
        self.startReadDrain()
    }

    private func doDisconnect() {
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
        lastSentSize = nil
        capsAnnounced = false
        // readSource 在 fd close 后会自动 EOF, 但显式 cancel 更干净
        if let src = readSource {
            src.cancel()
            readSource = nil
        }
    }

    /// 拼 ANNOUNCE_CAPABILITIES 帧并写出. 36 字节 (chunk 8 + msg header 20 + payload 8).
    /// 失败返回 false, 调用方应 doDisconnect.
    private func sendAnnounceCapabilities() -> Bool {
        // VDAgentAnnounceCapabilities (8B): request=1 + caps[0] = (1 << CAP_MONITORS_CONFIG)
        var payloadBuf = Data(capacity: 8)
        VdagentClient.appendU32(1, to: &payloadBuf)  // request=1: 请对端回 announce
        VdagentClient.appendU32(1 << VdagentClient.VD_AGENT_CAP_MONITORS_CONFIG_BIT, to: &payloadBuf)

        var msgBuf = Data(capacity: 20 + payloadBuf.count)
        VdagentClient.appendU32(VdagentClient.VD_AGENT_PROTOCOL, to: &msgBuf)
        VdagentClient.appendU32(VdagentClient.VD_AGENT_ANNOUNCE_CAPABILITIES, to: &msgBuf)
        VdagentClient.appendU64(0, to: &msgBuf)
        VdagentClient.appendU32(UInt32(payloadBuf.count), to: &msgBuf)
        msgBuf.append(payloadBuf)

        var chunkBuf = Data(capacity: 8 + msgBuf.count)
        VdagentClient.appendU32(VdagentClient.VDP_CLIENT_PORT, to: &chunkBuf)
        VdagentClient.appendU32(UInt32(msgBuf.count), to: &chunkBuf)
        chunkBuf.append(msgBuf)

        if sendAll(chunkBuf) {
            log.info("vdagent ANNOUNCE_CAPABILITIES sent (caps=MONITORS_CONFIG, \(chunkBuf.count) bytes)")
            return true
        }
        return false
    }

    /// 后台 read loop: 解析 incoming chunks, 处理握手 reply.
    /// 关键: spice-vdagent.exe 服务在 connect com.redhat.spice.0 后**主动发**
    /// ANNOUNCE_CAPABILITIES (request=1), 等 client (我们) 发回 ANNOUNCE_CAPABILITIES
    /// (request=0, 我们的 caps). 收不到 reply 服务 stuck 不处理后续 MONITORS_CONFIG.
    /// 这就是为什么单纯发主动 ANNOUNCE 不够 — 双向握手必须各自 reply 对方的 announce.
    /// 我们 reply 后 buffer 里剩余字节继续丢弃 (其他 message type 我们不关心).
    private func startReadDrain() {
        guard sockFD >= 0, readSource == nil else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: sockFD, queue: queue)
        // 跨多次 event 累积的 buffer (chunk + msg header 可能跨 read 边界来)
        var rxBuffer = Data()
        src.setEventHandler { [weak self] in
            guard let self, self.sockFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.recv(self.sockFD, p.baseAddress, p.count, 0)
            }
            if n <= 0 {
                log.info("vdagent read EOF/err n=\(n) errno=\(errno)")
                src.cancel()
                return
            }
            log.info("vdagent ← read \(n) bytes (rxBuffer total=\(rxBuffer.count + n))")
            rxBuffer.append(contentsOf: buf[0..<n])
            // 尝试 parse 一个或多个完整 chunk
            self.consumeChunks(from: &rxBuffer)
        }
        src.setCancelHandler { [weak self] in
            self?.readSource = nil
        }
        src.resume()
        readSource = src
    }

    /// 从 rxBuffer 头部尽可能解 完整 chunk (chunk header 8B + msg body). 不全则保留.
    private func consumeChunks(from rxBuffer: inout Data) {
        while rxBuffer.count >= 8 {
            // chunk header: port (4B LE) + size (4B LE)
            let port = rxBuffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let size = Int(rxBuffer.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian })
            let preview = rxBuffer.prefix(min(8, rxBuffer.count)).map { String(format: "%02x", $0) }.joined()
            let curBufCount = rxBuffer.count
            log.info("vdagent chunk hdr: port=\(port) size=\(size) bytes=[\(preview)] rxBuffer=\(curBufCount)")
            // 整 chunk 长度 = 8 (header) + size (msg body)
            let chunkTotal = 8 + size
            if rxBuffer.count < chunkTotal {
                log.info("vdagent chunk incomplete, waiting (need \(chunkTotal), have \(curBufCount))")
                return
            }
            // 截取 chunk 整体
            let chunkBody = rxBuffer.subdata(in: 8..<chunkTotal)
            rxBuffer.removeSubrange(0..<chunkTotal)
            // chunk body = VDAgentMessage (20B header + payload). 解析 type
            if port == VdagentClient.VDP_CLIENT_PORT, chunkBody.count >= 20 {
                let msgType = chunkBody.withUnsafeBytes {
                    $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian
                }
                let bodyPreview = chunkBody.prefix(20).map { String(format: "%02x", $0) }.joined()
                log.info("vdagent msg type=\(msgType) bodyHdr=[\(bodyPreview)]")
                if msgType == VdagentClient.VD_AGENT_ANNOUNCE_CAPABILITIES {
                    log.info("vdagent ← agent ANNOUNCE_CAPABILITIES received, replying our caps")
                    _ = self.replyAnnounceCapabilities()
                } else if msgType == VdagentClient.VD_AGENT_REPLY, chunkBody.count >= 28 {
                    // VDAgentReply payload (8B at offset 20): type(4) + error(4)
                    let replyType = chunkBody.withUnsafeBytes {
                        $0.load(fromByteOffset: 20, as: UInt32.self).littleEndian
                    }
                    let replyErr = chunkBody.withUnsafeBytes {
                        $0.load(fromByteOffset: 24, as: UInt32.self).littleEndian
                    }
                    log.info("vdagent ← REPLY for msgType=\(replyType) error=\(replyErr) \(replyErr == 0 ? "(OK)" : "(FAIL)")")
                }
            } else {
                log.info("vdagent chunk skipped (port=\(port) bodyLen=\(chunkBody.count))")
            }
        }
    }

    /// 收到对端 ANNOUNCE 时回 一条 ANNOUNCE_CAPABILITIES (request=0) 完成握手.
    @discardableResult
    private func replyAnnounceCapabilities() -> Bool {
        var payloadBuf = Data(capacity: 8)
        VdagentClient.appendU32(0, to: &payloadBuf)  // request=0 (这是回复, 不要求对端再回)
        VdagentClient.appendU32(1 << VdagentClient.VD_AGENT_CAP_MONITORS_CONFIG_BIT, to: &payloadBuf)

        var msgBuf = Data(capacity: 20 + payloadBuf.count)
        VdagentClient.appendU32(VdagentClient.VD_AGENT_PROTOCOL, to: &msgBuf)
        VdagentClient.appendU32(VdagentClient.VD_AGENT_ANNOUNCE_CAPABILITIES, to: &msgBuf)
        VdagentClient.appendU64(0, to: &msgBuf)
        VdagentClient.appendU32(UInt32(payloadBuf.count), to: &msgBuf)
        msgBuf.append(payloadBuf)

        var chunkBuf = Data(capacity: 8 + msgBuf.count)
        VdagentClient.appendU32(VdagentClient.VDP_CLIENT_PORT, to: &chunkBuf)
        VdagentClient.appendU32(UInt32(msgBuf.count), to: &chunkBuf)
        chunkBuf.append(msgBuf)

        if sendAll(chunkBuf) {
            log.info("vdagent → ANNOUNCE_CAPABILITIES reply (request=0) sent (\(chunkBuf.count) bytes)")
            return true
        }
        log.warning("vdagent ANNOUNCE_CAPABILITIES reply 写失败")
        return false
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

    // MARK: - little-endian appenders

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
}
