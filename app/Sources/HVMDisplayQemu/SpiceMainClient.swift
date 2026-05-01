// HVMDisplayQemu/SpiceMainClient.swift
//
// SPICE main channel client (minimal). Host 端通过 QEMU 内嵌 spice-server 的 unix socket
// (`-spice unix=on,addr=...`) 走 SPICE 协议 main channel, 在 main channel 上发
// SPICE_MSGC_MAIN_AGENT_DATA 包裹 VDAgentMessage(MONITORS_CONFIG), spice-server 通过
// `-chardev spicevmc,name=vdagent` multiplex 到 guest 内 spice-vdagent 服务,
// 实现拖 HVM 主窗口动态 resize.
//
// 为啥不能裸 -chardev socket (旧 VdagentClient 路径):
//   guest 内 vdservice 在 raw chardev 模式下拒绝 forward MONITORS_CONFIG 给 user-session
//   vdagent.exe (实测 reply error=1 GENERIC), 必须经 spice-server 中转走「正常 SPICE 通路」
//   vdservice 才接受. 详见 commit f94d45e 已知 limitation 章节.
//
// 实现范围 (minimal):
//   - 仅 main channel, 不开 display / cursor / inputs / playback / record (HVM 走自家
//     iosurface backend + QMP input, SPICE display 通道完全不需要)
//   - 不做 SASL / TLS, 走 disable-ticketing=on (自家进程对自家进程, unix socket fs 权限护栏);
//     但仍走 SPICE_COMMON_CAP_AUTH_SPICE auth 流程发 128-byte 全 0 ticket, 因为 spice-server
//     即便 disable-ticketing 也强制走 link auth 阶段, 跳过会报 LINK_ERR_PERMISSION_DENIED
//   - MINI_HEADER (6B) data 头, 不走 legacy 18-byte SpiceDataHeader (协商 cap 后端必支持)
//   - 不实现 mouse / clipboard / file_xfer / display_caps; agent 端发回的 AGENT_DATA 全部 drain
//
// 协议依赖:
//   spice-protocol/spice/protocol.h: SpiceLinkHeader/Mess/Reply/AuthMechanism/EncryptedTicket/MiniDataHeader
//   spice-protocol/spice/enums.h:    SPICE_CHANNEL_MAIN / SPICE_LINK_ERR_OK / SPICE_MSG_*/MSGC_*
//   spice-protocol/spice/vd_agent.h: VDAgentMessage / VDAgentMonitorsConfig / VDAgentMonConfig /
//                                    VDAgentAnnounceCapabilities / VD_AGENT_CAP_MONITORS_CONFIG
//
// 失败策略 (跟 VdagentClient 对齐): 任何 link / IO 错误 silently swallow + log.warn,
// 重连留给下次 sendMonitorsConfig lazy 触发. UI 拖窗口不能因 vdagent 通路挂阻塞.

import Foundation
import Darwin
import OSLog
import Security

private let log = Logger(subsystem: "com.hellmessage.vm", category: "SpiceMain")

public final class SpiceMainClient: @unchecked Sendable {

    // MARK: - SPICE 协议常量 (跟 protocol.h / enums.h 同步; 不引 C header 避免 SwiftPM 加 systemLib)

    /// SPICE_MAGIC_CONST("REDQ"): 'R'<<24 | 'E'<<16 | 'D'<<8 | 'Q' (little-endian wire)
    /// 实际 wire 字节是 ['R','E','D','Q'] 顺序; 用 le u32 写 0x51444552 ("REDQ" 反字节序)
    private static let SPICE_MAGIC: UInt32 = 0x51444552
    private static let SPICE_VERSION_MAJOR: UInt32 = 2
    private static let SPICE_VERSION_MINOR: UInt32 = 2
    private static let SPICE_TICKET_KEY_PAIR_LENGTH: Int = 1024            // bits
    private static let SPICE_TICKET_PUBKEY_BYTES: Int = 1024 / 8 + 34      // 162

    // SpiceLinkErr enum
    private static let SPICE_LINK_ERR_OK: UInt32 = 0

    // common capability bits (LinkMess/LinkReply num_common_caps)
    private static let SPICE_COMMON_CAP_PROTOCOL_AUTH_SELECTION: UInt32 = 0
    private static let SPICE_COMMON_CAP_AUTH_SPICE: UInt32              = 1
    private static let SPICE_COMMON_CAP_MINI_HEADER: UInt32             = 3

    // channel type
    private static let SPICE_CHANNEL_MAIN: UInt8 = 1

    // base messages (server → client; 共用 1..100)
    private static let SPICE_MSG_MIGRATE: UInt16 = 1
    private static let SPICE_MSG_SET_ACK: UInt16 = 3
    private static let SPICE_MSG_PING: UInt16 = 4
    private static let SPICE_MSG_NOTIFY: UInt16 = 7

    // base messages (client → server; 共用 1..100)
    private static let SPICE_MSGC_ACK_SYNC: UInt16 = 1
    private static let SPICE_MSGC_ACK: UInt16 = 2
    private static let SPICE_MSGC_PONG: UInt16 = 3

    // main channel server → client (101..)
    private static let SPICE_MSG_MAIN_INIT: UInt16 = 103
    private static let SPICE_MSG_MAIN_CHANNELS_LIST: UInt16 = 104
    private static let SPICE_MSG_MAIN_MOUSE_MODE: UInt16 = 105
    private static let SPICE_MSG_MAIN_MULTI_MEDIA_TIME: UInt16 = 106
    private static let SPICE_MSG_MAIN_AGENT_CONNECTED: UInt16 = 107
    private static let SPICE_MSG_MAIN_AGENT_DISCONNECTED: UInt16 = 108
    private static let SPICE_MSG_MAIN_AGENT_DATA: UInt16 = 109
    private static let SPICE_MSG_MAIN_AGENT_TOKEN: UInt16 = 110
    private static let SPICE_MSG_MAIN_AGENT_CONNECTED_TOKENS: UInt16 = 115

    // main channel client → server (101..)
    private static let SPICE_MSGC_MAIN_ATTACH_CHANNELS: UInt16 = 104
    private static let SPICE_MSGC_MAIN_AGENT_START: UInt16 = 106
    private static let SPICE_MSGC_MAIN_AGENT_DATA: UInt16 = 107
    private static let SPICE_MSGC_MAIN_AGENT_TOKEN: UInt16 = 108

    // VD_AGENT 协议 (跟 VdagentClient 同, 这里不再走裸 chardev 路径但 message 格式一样)
    private static let VD_AGENT_PROTOCOL: UInt32 = 1
    private static let VD_AGENT_MONITORS_CONFIG: UInt32 = 2
    private static let VD_AGENT_REPLY: UInt32 = 3
    private static let VD_AGENT_ANNOUNCE_CAPABILITIES: UInt32 = 6
    /// VD_AGENT_CAP_* enum bits (vd_agent.h). 必须跟 UTM/spice-gtk 通报的同集合, 否则
    /// guest 内 spice-vdagent (vdservice + vdagent.exe) 视我们为"非真实 SPICE client"
    /// 默默丢弃 MONITORS_CONFIG. 实测仅通报 MONITORS_CONFIG + REPLY 时 vdagent.exe 不改
    /// 分辨率; 跟 UTM 对齐通报 10 bit 集合后 vdservice 才 forward 给 vdagent.exe.
    private static let VD_AGENT_CAP_MOUSE_STATE_BIT: UInt32                  = 0
    private static let VD_AGENT_CAP_MONITORS_CONFIG_BIT: UInt32              = 1
    private static let VD_AGENT_CAP_REPLY_BIT: UInt32                        = 2
    private static let VD_AGENT_CAP_DISPLAY_CONFIG_BIT: UInt32               = 3
    private static let VD_AGENT_CAP_CLIPBOARD_BY_DEMAND_BIT: UInt32          = 5
    private static let VD_AGENT_CAP_CLIPBOARD_SELECTION_BIT: UInt32          = 6
    private static let VD_AGENT_CAP_MONITORS_CONFIG_POSITION_BIT: UInt32     = 9
    private static let VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS_BIT: UInt32    = 10
    private static let VD_AGENT_CAP_CLIPBOARD_NO_RELEASE_ON_REGRAB_BIT: UInt32 = 14
    private static let VD_AGENT_CAP_CLIPBOARD_GRAB_SERIAL_BIT: UInt32        = 16

    /// VDAgentMonitorsConfig flags: USE_POS = 1 (跟 UTM 对齐, 让 client 端 x/y 位置生效).
    /// 不通报 USE_POS, vdagent windows 端会自动 align 多显示器, 单显示器无 visible 影响,
    /// 但 spice-gtk/UTM 默认开, 跟着行为对齐.
    private static let VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS: UInt32 = 1 << 0

    /// 我们发给 agent 的 token 数 (告诉 agent 一次最多发多少 message 给我们).
    /// 32 是 spice-gtk 默认值, 够大不会 stall.
    private static let CLIENT_TOKENS_TO_AGENT: UInt32 = 32

    // MARK: - 状态

    private let socketPath: String
    private let queue = DispatchQueue(label: "hvm.spice.main", qos: .userInitiated)
    private var sockFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// 跨多次 read event 累积的入站 buffer (mini header 6B + payload 可能跨边界)
    private var rxBuffer = Data()

    /// link handshake 完成 (开始走 mini-data-header 阶段)
    private var linkComplete: Bool = false
    /// guest 端 vdservice 已 attach 到 spicevmc (server 已通知 AGENT_CONNECTED).
    /// 仅在 true 时 sendMonitorsConfig 才会真发, 否则先 buffer 最后一个 size.
    private var agentConnected: Bool = false
    /// agent 余 tokens (server 给我们的, 控制 client → server agent_data 流速).
    /// 0 时不能再发 agent_data; 收到 AGENT_TOKEN 增加.
    private var agentTokens: UInt32 = 0
    /// 已发过自身 ANNOUNCE_CAPABILITIES (agent 端握手第 1 步).
    /// agent_connected 后我们立刻发, 之后 dedup.
    private var announceCapsSent: Bool = false
    /// 上次发送的 MonitorsConfig (dedup, 同尺寸不重发).
    private var lastSentSize: (width: UInt32, height: UInt32)?
    /// 待发 MonitorsConfig (agent 还没 connected 时缓存, connected 后自动 flush).
    private var pendingMonitorsConfig: (width: UInt32, height: UInt32)?

    // MARK: - 公开 API

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        if sockFD >= 0 { Darwin.close(sockFD); sockFD = -1 }
    }

    /// 异步 connect SPICE socket + 走 link handshake. 失败 silently, 后续 send 静默丢弃.
    /// 已连断了再调 connect 会重连.
    public func connect() {
        queue.async { [weak self] in self?.doConnect() }
    }

    public func disconnect() {
        queue.async { [weak self] in self?.doDisconnect() }
    }

    /// 发 VDAgentMonitorsConfig 给 guest spice-vdagent. 单显示器, 32-bit color, 原点 0,0.
    /// dedup: 同尺寸不重发.
    /// agent 还没 connected 时缓存到 pendingMonitorsConfig, connected 后自动 flush.
    public func sendMonitorsConfig(width: UInt32, height: UInt32) {
        queue.async { [weak self] in
            guard let self else { return }
            // dedup
            if let last = self.lastSentSize, last.width == width, last.height == height {
                return
            }
            // 没连先 lazy connect; 还在 link 阶段或 agent 没 connected, 缓存等 flush
            if self.sockFD < 0 {
                self.doConnect()
            }
            if !self.linkComplete || !self.agentConnected {
                self.pendingMonitorsConfig = (width, height)
                log.info("SPICE: agent 未就绪, 缓存 MonitorsConfig \(width)x\(height) 待 connected 后 flush")
                return
            }
            self.lastSentSize = (width, height)
            self.flushMonitorsConfig(width: width, height: height)
        }
    }

    // MARK: - 连接 + link handshake

    private func doConnect() {
        guard sockFD < 0 else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.warning("SPICE: socket() errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathLimit else {
            Darwin.close(fd)
            log.warning("SPICE: socket path too long: \(self.socketPath)")
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
            log.warning("SPICE: connect errno=\(saved) path=\(self.socketPath)")
            return
        }
        // 关 SIGPIPE: macOS 上 socket 写到对端关闭时默认 raise SIGPIPE 杀进程
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        sockFD = fd
        log.info("SPICE: connected to \(self.socketPath), starting link handshake")

        // SPICE link handshake — 同步阻塞做完 (link 阶段几 KB 数据, 不占主路径很久)
        // 完成后切到 mini-header data 阶段, 由 readSource async 驱动
        if !performLinkHandshake() {
            log.warning("SPICE: link handshake failed, 关连接")
            doDisconnect()
            return
        }
        linkComplete = true
        log.info("SPICE: link handshake OK, entering main channel data phase")

        startReadDrain()
    }

    private func doDisconnect() {
        if let src = readSource {
            src.cancel()
            readSource = nil
        }
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
        rxBuffer.removeAll(keepingCapacity: false)
        linkComplete = false
        agentConnected = false
        agentTokens = 0
        announceCapsSent = false
        lastSentSize = nil
        // 不清 pendingMonitorsConfig — 下次 connect 完成后重 flush 用户最后期望的尺寸
    }

    /// SPICE link handshake 完整流程. 同步阻塞 read/write, 只在 connect() 结束阶段调用.
    /// 失败返回 false, 调用方 disconnect 即可.
    private func performLinkHandshake() -> Bool {
        // 1) 构造 LinkMess + caps
        // num_common_caps = 1 (我们至少要 MINI_HEADER bit, 否则 server 会强制走 18B header)
        // num_channel_caps = 0 (main channel 我们不需要 main-specific cap)
        // 通报的 common cap bitmask: PROTOCOL_AUTH_SELECTION + AUTH_SPICE + MINI_HEADER
        // (PROTOCOL_AUTH_SELECTION 让我们走 SpiceLinkAuthMechanism 选择路径而不是 legacy ticket;
        //  AUTH_SPICE 表示我们支持发 RSA ticket; MINI_HEADER 让 data 阶段走 6B 头)
        let commonCapsBitmask: UInt32 =
            (1 << Self.SPICE_COMMON_CAP_PROTOCOL_AUTH_SELECTION) |
            (1 << Self.SPICE_COMMON_CAP_AUTH_SPICE) |
            (1 << Self.SPICE_COMMON_CAP_MINI_HEADER)
        let numCommonCaps: UInt32 = 1
        let numChannelCaps: UInt32 = 0
        // SpiceLinkMess: 18B (connection_id u32 + channel_type u8 + channel_id u8 +
        //                     num_common_caps u32 + num_channel_caps u32 + caps_offset u32)
        let linkMessSize = 18
        let capsOffset: UInt32 = 18              // caps 紧跟在 LinkMess 后面
        let capsBytes = Int(numCommonCaps + numChannelCaps) * 4
        let totalLinkPayload = linkMessSize + capsBytes        // = 18 + 4 = 22

        var linkBuf = Data(capacity: 16 + totalLinkPayload)
        // SpiceLinkHeader (16B): magic / major / minor / size
        Self.appendU32(Self.SPICE_MAGIC, to: &linkBuf)
        Self.appendU32(Self.SPICE_VERSION_MAJOR, to: &linkBuf)
        Self.appendU32(Self.SPICE_VERSION_MINOR, to: &linkBuf)
        Self.appendU32(UInt32(totalLinkPayload), to: &linkBuf)
        // SpiceLinkMess
        Self.appendU32(0, to: &linkBuf)                            // connection_id (0 = new session)
        linkBuf.append(Self.SPICE_CHANNEL_MAIN)                    // channel_type
        linkBuf.append(0)                                          // channel_id
        Self.appendU32(numCommonCaps, to: &linkBuf)
        Self.appendU32(numChannelCaps, to: &linkBuf)
        Self.appendU32(capsOffset, to: &linkBuf)
        // common caps[0]
        Self.appendU32(commonCapsBitmask, to: &linkBuf)

        guard sendAll(linkBuf) else { return false }

        // 2) 收 LinkHeader (16B) — 必须先读 header 才知 LinkReply payload 多大
        guard let respHdr = recvExact(16) else { return false }
        let respMagic = respHdr.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let respMajor = respHdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let respMinor = respHdr.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self).littleEndian }
        let respSize  = respHdr.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self).littleEndian }
        guard respMagic == Self.SPICE_MAGIC else {
            log.warning("SPICE: bad reply magic 0x\(String(respMagic, radix: 16))")
            return false
        }
        guard respMajor == Self.SPICE_VERSION_MAJOR else {
            log.warning("SPICE: version major mismatch ours=\(Self.SPICE_VERSION_MAJOR) server=\(respMajor)")
            return false
        }
        // minor 不强制等, 取小者作 effective; 我们没用 cap-flag 跨 minor 行为
        _ = respMinor
        // SpiceLinkReply 至少 178B (4 error + 162 pub_key + 4*3 caps fields), 加 caps 数组
        guard respSize >= 178 else {
            log.warning("SPICE: reply size too small \(respSize)")
            return false
        }
        guard let replyBody = recvExact(Int(respSize)) else { return false }
        let linkErr = replyBody.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        guard linkErr == Self.SPICE_LINK_ERR_OK else {
            log.warning("SPICE: link reply error=\(linkErr)")
            return false
        }
        // pub_key (SPICE_TICKET_PUBKEY_BYTES=162) 是 X.509 SubjectPublicKeyInfo
        // 包裹 RSA-1024 公钥. spice-server 即便 disable-ticketing=on 也要 RSA-OAEP-SHA1
        // 解密我们发的 ticket (校验阶段才跳过内容验证). 我们必须发**合法**的 OAEP 密文,
        // 用 server pubkey 加密空字符串. 发 128 字节全 0 会让 OpenSSL OAEP decode 报
        // "oaep decoding error" → server 回 SPICE_LINK_ERR_PERMISSION_DENIED.
        let pubKeySPKI = replyBody.subdata(in: 4..<(4 + 162))
        let serverNumCommonCaps   = replyBody.withUnsafeBytes { $0.load(fromByteOffset: 4 + 162, as: UInt32.self).littleEndian }
        let serverNumChannelCaps  = replyBody.withUnsafeBytes { $0.load(fromByteOffset: 4 + 162 + 4, as: UInt32.self).littleEndian }
        let serverCapsOffset      = Int(replyBody.withUnsafeBytes { $0.load(fromByteOffset: 4 + 162 + 8, as: UInt32.self).littleEndian })
        // 校验 server 通报了 MINI_HEADER cap, 否则我们要回退 18B header (现在不实现, 直接拒)
        var serverCommonBitmask: UInt32 = 0
        if serverNumCommonCaps >= 1 && serverCapsOffset + 4 <= replyBody.count {
            serverCommonBitmask = replyBody.withUnsafeBytes {
                $0.load(fromByteOffset: serverCapsOffset, as: UInt32.self).littleEndian
            }
        }
        let serverHasMiniHeader = (serverCommonBitmask & (1 << Self.SPICE_COMMON_CAP_MINI_HEADER)) != 0
        if !serverHasMiniHeader {
            log.warning("SPICE: server 不支持 MINI_HEADER (caps=0x\(String(serverCommonBitmask, radix: 16))), 拒")
            return false
        }
        _ = serverNumChannelCaps     // main channel 我们没读 channel-specific caps

        // 3) 发 SpiceLinkAuthMechanism (4B) 选 SPICE_COMMON_CAP_AUTH_SPICE
        var authBuf = Data(capacity: 4)
        Self.appendU32(Self.SPICE_COMMON_CAP_AUTH_SPICE, to: &authBuf)
        guard sendAll(authBuf) else { return false }

        // 4) 发 SpiceLinkEncryptedTicket: 128 字节 RSA-OAEP-SHA1 密文 (SPICE_TICKET_KEY_PAIR_LENGTH/8).
        // 必须用 server 给的 pubkey 真加密 (空字符串作 plaintext), 全 0 字节会被 OpenSSL OAEP
        // 解码拒. spice-server 在 disable-ticketing=on 下不验证 plaintext 内容, 但仍走 RSA decrypt.
        guard let ticketBuf = Self.encryptSpiceTicket(pubKeySPKI: pubKeySPKI) else {
            log.warning("SPICE: 加密空 ticket 失败 (pubkey parse / OAEP)")
            return false
        }
        guard sendAll(ticketBuf) else { return false }

        // 5) 收 4B SpiceLinkErr — server 端 auth 验证结果
        guard let authResult = recvExact(4) else { return false }
        let authErr = authResult.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        guard authErr == Self.SPICE_LINK_ERR_OK else {
            log.warning("SPICE: auth error=\(authErr)")
            return false
        }

        return true
    }

    // MARK: - data 阶段 (mini header 6B)

    /// 后台 read loop: 用 DispatchSourceRead 避免阻塞调用线程.
    /// rxBuffer 跨多次 event 累积, consumeMessages 尽可能解尽完整 message.
    private func startReadDrain() {
        guard sockFD >= 0, readSource == nil else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: sockFD, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.sockFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.recv(self.sockFD, p.baseAddress, p.count, 0)
            }
            if n <= 0 {
                log.info("SPICE: read EOF/err n=\(n) errno=\(errno)")
                src.cancel()
                self.doDisconnect()
                return
            }
            self.rxBuffer.append(contentsOf: buf[0..<n])
            self.consumeMessages()
        }
        src.setCancelHandler { [weak self] in
            self?.readSource = nil
        }
        src.resume()
        readSource = src
    }

    /// 从 rxBuffer 头部尽可能解出完整的 mini-header message. 不全则保留.
    /// mini header (6B): type u16 + size u32; 后面紧跟 size 字节 payload.
    private func consumeMessages() {
        while rxBuffer.count >= 6 {
            let type = rxBuffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self).littleEndian }
            let size = Int(rxBuffer.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt32.self).littleEndian })
            let total = 6 + size
            if rxBuffer.count < total { return }
            let payload = rxBuffer.subdata(in: 6..<total)
            rxBuffer.removeSubrange(0..<total)
            handleServerMessage(type: type, payload: payload)
        }
    }

    private func handleServerMessage(type: UInt16, payload: Data) {
        switch type {
        case Self.SPICE_MSG_SET_ACK:
            // payload: SpiceMsgSetAck { generation u32, window u32 } — 我们必须回 ACK_SYNC
            // (告诉 server 我们已对齐 ack generation, 否则 server 会停等)
            if payload.count >= 8 {
                let generation = payload.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                sendAckSync(generation: generation)
            }

        case Self.SPICE_MSG_PING:
            // payload: SpiceMsgPing { id u32, timestamp u64 } — 回 PONG (id + timestamp echo)
            if payload.count >= 12 {
                var pong = Data(capacity: 12)
                pong.append(payload.subdata(in: 0..<12))
                sendMiniMessage(type: Self.SPICE_MSGC_PONG, payload: pong)
            }

        case Self.SPICE_MSG_MAIN_INIT:
            // payload: SpiceMsgMainInit (24B):
            //   session_id u32, display_channels_hint u32, supported_mouse_modes u32,
            //   current_mouse_mode u32, agent_connected u32, agent_tokens u32 (+ time/ram_hint)
            // 关键: agent_connected + agent_tokens 直接给我们 agent 状态.
            if payload.count >= 24 {
                let agentConn   = payload.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }
                let initTokens  = payload.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self).littleEndian }
                log.info("SPICE: MAIN_INIT agent_connected=\(agentConn) agent_tokens=\(initTokens)")
                if agentConn != 0 {
                    onAgentConnected(serverTokens: initTokens)
                }
            }
            // ATTACH_CHANNELS: 通知 server 我们准备好接收剩余 channel list (空 payload)
            sendMiniMessage(type: Self.SPICE_MSGC_MAIN_ATTACH_CHANNELS, payload: Data())

        case Self.SPICE_MSG_MAIN_AGENT_CONNECTED:
            // 旧协议无 token 字段. 给个保守 tokens 让 ANNOUNCE 能发出去.
            log.info("SPICE: AGENT_CONNECTED (legacy no-token form)")
            onAgentConnected(serverTokens: 10)

        case Self.SPICE_MSG_MAIN_AGENT_CONNECTED_TOKENS:
            // payload: u32 num_tokens — server 给我们最初的 agent_data send window
            if payload.count >= 4 {
                let initTokens = payload.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                log.info("SPICE: AGENT_CONNECTED_TOKENS tokens=\(initTokens)")
                onAgentConnected(serverTokens: initTokens)
            }

        case Self.SPICE_MSG_MAIN_AGENT_DISCONNECTED:
            log.info("SPICE: AGENT_DISCONNECTED (vdservice 在 guest 内停了)")
            agentConnected = false
            agentTokens = 0
            announceCapsSent = false

        case Self.SPICE_MSG_MAIN_AGENT_TOKEN:
            // payload: u32 num_tokens — server 还我们的 send window
            if payload.count >= 4 {
                let added = payload.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                agentTokens = agentTokens &+ added
            }

        case Self.SPICE_MSG_MAIN_AGENT_DATA:
            // agent → client 方向. payload 是裸 VDAgentMessage (20B header + body),
            // **没有** VDIChunkHeader (spice-server 已剥). 我们解析 type 处理 ANNOUNCE
            // (双向握手第 2 步: 收到 agent ANNOUNCE 时回我们的 ANNOUNCE request=0).
            // REPLY 仅 log 不 act.
            handleAgentData(payload: payload)

        case Self.SPICE_MSG_MAIN_MOUSE_MODE,
             Self.SPICE_MSG_MAIN_MULTI_MEDIA_TIME,
             Self.SPICE_MSG_MAIN_CHANNELS_LIST,
             Self.SPICE_MSG_MIGRATE,
             Self.SPICE_MSG_NOTIFY:
            // 我们不关心: mouse mode / time / channels list / migrate / notify
            // 严格按 size 跳过即可 (consumeMessages 已 advance buffer, 这里 noop)
            break

        default:
            // 未识别的 type: 按 size 跳过 (consumeMessages 已 advance buffer), 不报错
            log.debug("SPICE: skip unknown server msg type=\(type) size=\(payload.count)")
        }
    }

    private func onAgentConnected(serverTokens: UInt32) {
        agentConnected = true
        agentTokens = serverTokens
        // **关键** 第一件事: 发 SPICE_MSGC_MAIN_AGENT_START 通知 server 我们准备好接收
        // agent → client 数据 (并附我们能消化多少 token). 没这个 spice-server 不 forward
        // vdservice 端发的 ANNOUNCE_CAPABILITIES 给我们 → vdservice 卡在等 caps 协商 →
        // 整个 vdagent 通路死锁 → 影响 Win user session 启动 (OOBE Welcome 卡死).
        sendAgentStart(numTokens: Self.CLIENT_TOKENS_TO_AGENT)
        // 然后发 ANNOUNCE_CAPABILITIES (request=1) 让 vdservice 知道 client 支持 MONITORS_CONFIG
        if !announceCapsSent {
            if sendAnnounceCapabilities(request: 1) {
                announceCapsSent = true
            }
        }
        // flush pending MonitorsConfig (用户在 link 完成前就拖了窗口)
        if let pending = pendingMonitorsConfig {
            log.info("SPICE: agent ready, flush pending MonitorsConfig \(pending.width)x\(pending.height)")
            pendingMonitorsConfig = nil
            lastSentSize = (pending.width, pending.height)
            flushMonitorsConfig(width: pending.width, height: pending.height)
        }
    }

    private func handleAgentData(payload: Data) {
        // VDAgentMessage 头 (20B): protocol u32 + type u32 + opaque u64 + size u32
        guard payload.count >= 20 else { return }
        let msgType = payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        switch msgType {
        case Self.VD_AGENT_ANNOUNCE_CAPABILITIES:
            // request=1 表示 agent 期望我们也回一个 (request=0). 简化: 收到任何 ANNOUNCE
            // 都回一次 (幂等, 不影响). 双向握手第 2 步.
            log.info("SPICE: ← agent ANNOUNCE_CAPABILITIES, replying request=0")
            _ = sendAnnounceCapabilities(request: 0)
        case Self.VD_AGENT_REPLY:
            // VDAgentReply (8B at offset 20): type u32 + error u32
            if payload.count >= 28 {
                let replyType = payload.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self).littleEndian }
                let replyErr  = payload.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self).littleEndian }
                if replyErr != 0 {
                    log.warning("SPICE: ← agent REPLY type=\(replyType) error=\(replyErr) FAIL")
                } else {
                    log.info("SPICE: ← agent REPLY type=\(replyType) OK")
                }
            }
        default:
            // mouse_state / clipboard / display_config / file_xfer 等我们不关心
            break
        }
    }

    // MARK: - 发 mini message + agent_data 包装

    /// 发一个 mini-header message: 6B header (type + size) + payload bytes
    @discardableResult
    private func sendMiniMessage(type: UInt16, payload: Data) -> Bool {
        var buf = Data(capacity: 6 + payload.count)
        Self.appendU16(type, to: &buf)
        Self.appendU32(UInt32(payload.count), to: &buf)
        buf.append(payload)
        return sendAll(buf)
    }

    private func sendAckSync(generation: UInt32) {
        var buf = Data(capacity: 4)
        Self.appendU32(generation, to: &buf)
        sendMiniMessage(type: Self.SPICE_MSGC_ACK_SYNC, payload: buf)
    }

    /// SPICE_MSGC_MAIN_AGENT_TOKEN: 通知 server 我们消化了 N 个 agent → client 消息,
    /// 还回 N tokens 让 server 继续发. 流控用, agent boot 后周期性发.
    private func sendAgentTokens(_ tokens: UInt32) {
        var buf = Data(capacity: 4)
        Self.appendU32(tokens, to: &buf)
        sendMiniMessage(type: Self.SPICE_MSGC_MAIN_AGENT_TOKEN, payload: buf)
    }

    /// SPICE_MSGC_MAIN_AGENT_START: AGENT_CONNECTED 后**必发**, 告诉 server "client 端
    /// 准备好接收 agent 数据了, 给我们 N tokens 的 send window". 没这个 spice-server
    /// 不会 forward vdservice 发的任何数据给 client. payload 是 SpiceMsgcMainAgentStart
    /// (4B u32 num_tokens).
    private func sendAgentStart(numTokens: UInt32) {
        var buf = Data(capacity: 4)
        Self.appendU32(numTokens, to: &buf)
        if sendMiniMessage(type: Self.SPICE_MSGC_MAIN_AGENT_START, payload: buf) {
            log.info("SPICE: → AGENT_START (num_tokens=\(numTokens))")
        }
    }

    /// 包 VDAgentMessage 进 SPICE_MSGC_MAIN_AGENT_DATA 发出去.
    /// payload = 20B VDAgentMessage 头 + msgBody (例如 VDAgentMonitorsConfig).
    /// 注意: spice-server 自己负责加 VDIChunkHeader; 我们**不**加.
    /// agentTokens 检查: 没 token 就丢 (reconnect 后 server 会重发 init tokens).
    @discardableResult
    private func sendAgentData(vdAgentType: UInt32, body: Data) -> Bool {
        guard agentConnected else {
            log.warning("SPICE: agent 未 connected, sendAgentData(type=\(vdAgentType)) 丢弃")
            return false
        }
        guard agentTokens > 0 else {
            log.warning("SPICE: agentTokens=0, sendAgentData(type=\(vdAgentType)) 丢弃")
            return false
        }
        var msg = Data(capacity: 20 + body.count)
        Self.appendU32(Self.VD_AGENT_PROTOCOL, to: &msg)   // protocol = 1
        Self.appendU32(vdAgentType, to: &msg)
        Self.appendU64(0, to: &msg)                        // opaque
        Self.appendU32(UInt32(body.count), to: &msg)
        msg.append(body)
        if sendMiniMessage(type: Self.SPICE_MSGC_MAIN_AGENT_DATA, payload: msg) {
            agentTokens &-= 1
            return true
        }
        return false
    }

    @discardableResult
    private func sendAnnounceCapabilities(request: UInt32) -> Bool {
        // VDAgentAnnounceCapabilities (8B): request u32 + caps[0] u32
        var body = Data(capacity: 8)
        Self.appendU32(request, to: &body)
        // 跟 UTM/spice-gtk 对齐通报完整 cap 集合 (10 bit). 关键: 必须含 MOUSE_STATE,
        // 否则 spice-vdagent windows 端把我们当成残缺 client 默默丢弃 MONITORS_CONFIG.
        // 实测仅通报 MONITORS_CONFIG + REPLY 时 vdservice 不 forward 给 vdagent.exe.
        let caps: UInt32 =
            (1 << Self.VD_AGENT_CAP_MOUSE_STATE_BIT) |
            (1 << Self.VD_AGENT_CAP_MONITORS_CONFIG_BIT) |
            (1 << Self.VD_AGENT_CAP_REPLY_BIT) |
            (1 << Self.VD_AGENT_CAP_DISPLAY_CONFIG_BIT) |
            (1 << Self.VD_AGENT_CAP_CLIPBOARD_BY_DEMAND_BIT) |
            (1 << Self.VD_AGENT_CAP_CLIPBOARD_SELECTION_BIT) |
            (1 << Self.VD_AGENT_CAP_MONITORS_CONFIG_POSITION_BIT) |
            (1 << Self.VD_AGENT_CAP_FILE_XFER_DETAILED_ERRORS_BIT) |
            (1 << Self.VD_AGENT_CAP_CLIPBOARD_NO_RELEASE_ON_REGRAB_BIT) |
            (1 << Self.VD_AGENT_CAP_CLIPBOARD_GRAB_SERIAL_BIT)
        Self.appendU32(caps, to: &body)
        let ok = sendAgentData(vdAgentType: Self.VD_AGENT_ANNOUNCE_CAPABILITIES, body: body)
        if ok {
            log.info("SPICE: → ANNOUNCE_CAPABILITIES (request=\(request), caps=0x\(String(caps, radix: 16)))")
        }
        return ok
    }
    
    /// 拼 VDAgentMonitorsConfig + 1 个 VDAgentMonConfig (单显示器, 32-bit color, 0,0 起点)
    /// 然后通过 sendAgentData 发出去.
    private func flushMonitorsConfig(width: UInt32, height: UInt32) {
        // VDAgentMonConfig (20B): height u32 + width u32 + depth u32 + x i32 + y i32
        var mon = Data(capacity: 20)
        Self.appendU32(height, to: &mon)
        Self.appendU32(width,  to: &mon)
        Self.appendU32(32,     to: &mon)         // depth bits
        Self.appendI32(0,      to: &mon)         // x
        Self.appendI32(0,      to: &mon)         // y
        // VDAgentMonitorsConfig (8B): num_of_monitors u32 + flags u32
        // flags = USE_POS: 跟 UTM/spice-gtk 对齐, 让 client 端 x/y 字段生效 (不写 USE_POS
        // 时 vdagent windows 自动 align 多显示器, 单显示器无 visible 影响, 但跟着行为对齐).
        var cfg = Data(capacity: 8 + 20)
        Self.appendU32(1, to: &cfg)              // num_of_monitors
        Self.appendU32(Self.VD_AGENT_CONFIG_MONITORS_FLAG_USE_POS, to: &cfg)
        cfg.append(mon)
        if sendAgentData(vdAgentType: Self.VD_AGENT_MONITORS_CONFIG, body: cfg) {
            log.info("SPICE: → MONITORS_CONFIG \(width)x\(height) (\(cfg.count) bytes body)")
        } else {
            log.warning("SPICE: MONITORS_CONFIG send failed")
        }
    }

    // MARK: - 底层 IO 工具

    private func sendAll(_ buf: Data) -> Bool {
        return buf.withUnsafeBytes { ptr -> Bool in
            var off = 0
            let total = buf.count
            while off < total {
                let r = Darwin.send(sockFD, ptr.baseAddress!.advanced(by: off), total - off, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += r
            }
            return true
        }
    }

    /// 同步阻塞读 exact n 字节. 用于 link handshake (data 阶段走 DispatchSourceRead).
    /// EOF / error 返回 nil; 调用方 disconnect 即可.
    private func recvExact(_ n: Int) -> Data? {
        var buf = Data(count: n)
        let ok = buf.withUnsafeMutableBytes { mp -> Bool in
            var off = 0
            while off < n {
                let r = Darwin.recv(sockFD, mp.baseAddress!.advanced(by: off), n - off, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if r == 0 { return false }       // EOF
                off += r
            }
            return true
        }
        return ok ? buf : nil
    }

    // MARK: - RSA-OAEP-SHA1 加密 (空 ticket)

    /// 用 162 字节 X.509 SPKI 包裹的 RSA-1024 公钥, 对空字符串做 RSA-OAEP-SHA1 加密.
    /// 返回 128 字节密文 (SPICE_TICKET_KEY_PAIR_LENGTH/8).
    /// 失败返回 nil (SPKI 格式异常 / Security.framework 加密失败).
    ///
    /// 实现细节:
    /// - macOS Security.framework `SecKeyCreateWithData` 接受的 RSA pubkey 是 **PKCS#1**
    ///   (`RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`),
    ///   不直接吃 X.509 SPKI. 必须先剥前 22 字节 SPKI wrapper, 拿内层 PKCS#1.
    /// - SPICE 的 162 字节 pubkey 对 RSA-1024 有固定的 22-byte wrapper:
    ///   `30 81 9F   30 0D 06 09 2A 86 48 86 F7 0D 01 01 01   05 00   03 81 8D   00`
    ///   (SEQUENCE + algoIdent SEQUENCE + OID rsaEncryption + NULL params + BIT STRING + 0 pad)
    ///   剥后剩 140 字节就是 PKCS#1 RSAPublicKey.
    /// - SecKey 的 OAEP 算法用 `.rsaEncryptionOAEPSHA1`, 跟 spice-server (OpenSSL EVP_PKEY_decrypt
    ///   with RSA_PKCS1_OAEP_PADDING + SHA1) 对齐.
    private static func encryptSpiceTicket(pubKeySPKI: Data) -> Data? {
        // 健壮性: SPKI 长度 162, wrapper 22, PKCS#1 = 140; 任何不符直接 nil 让上层 disconnect
        guard pubKeySPKI.count == 162 else {
            log.warning("SPICE: pubkey size unexpected \(pubKeySPKI.count) (期望 162)")
            return nil
        }
        // 剥 22 字节 SPKI wrapper
        let pkcs1 = pubKeySPKI.subdata(in: 22..<162)
        // 简易 sanity check: PKCS#1 应以 SEQUENCE (0x30) 开头
        guard pkcs1.count >= 4, pkcs1[0] == 0x30 else {
            log.warning("SPICE: PKCS#1 inner not SEQUENCE (byte0=0x\(String(pkcs1.first ?? 0, radix: 16)))")
            return nil
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let pubKey = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            let errDesc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            log.warning("SPICE: SecKeyCreateWithData failed: \(errDesc)")
            return nil
        }
        let plaintext = Data()       // 空字符串 (disable-ticketing=on 时 server 不验证内容)
        guard let cipher = SecKeyCreateEncryptedData(
            pubKey, .rsaEncryptionOAEPSHA1, plaintext as CFData, &error
        ) else {
            let errDesc = error?.takeRetainedValue().localizedDescription ?? "unknown"
            log.warning("SPICE: SecKeyCreateEncryptedData OAEP-SHA1 failed: \(errDesc)")
            return nil
        }
        let cipherData = cipher as Data
        guard cipherData.count == Self.SPICE_TICKET_KEY_PAIR_LENGTH / 8 else {
            log.warning("SPICE: ticket cipher size \(cipherData.count) (期望 128)")
            return nil
        }
        return cipherData
    }

    // MARK: - little-endian appenders (跟 VdagentClient 对齐)

    private static func appendU16(_ v: UInt16, to buf: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { buf.append(contentsOf: $0) }
    }
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
