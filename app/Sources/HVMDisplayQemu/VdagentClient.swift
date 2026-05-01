// HVMDisplayQemu/VdagentClient.swift
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
//   data 视 type 而定. MONITORS_CONFIG 数据:
//     VDAgentMonitorsConfig (8B): { num_of_monitors: u32, flags: u32 }
//     VDAgentMonConfig (20B) × N: { height, width, depth, x, y } — 全 u32/i32
//   单显示器 + 1 个 MonConfig = 8+20 = 28B; 整 message = 20+28 = 48B; 整 chunk = 8+48 = 56B.
//
// 失败策略: 任何 socket / write 错误 silently swallow + log.warn — vdagent 通道挂了
// 不能阻塞 user 拖窗口 / 让画面卡死, 老 framebuffer 仍能渲染.

import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "Vdagent")

public final class VdagentClient: @unchecked Sendable {

    // VD_AGENT 协议常量 (跟 spice-protocol/spice/vd_agent.h 同步)
    private static let VDP_CLIENT_PORT: UInt32 = 1
    private static let VD_AGENT_PROTOCOL: UInt32 = 1
    private static let VD_AGENT_MONITORS_CONFIG: UInt32 = 2

    private let socketPath: String
    private let queue = DispatchQueue(label: "hvm.vdagent.client", qos: .userInitiated)
    private var sockFD: Int32 = -1
    /// 上次发送的 MonitorsConfig (用于 dedup, 同尺寸不重复发).
    private var lastSentSize: (width: UInt32, height: UInt32)?

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
                log.warning("vdagent send failed (\(width)x\(height)) errno=\(errno), 关连接等下次 lazy 重连")
                self.doDisconnect()
            } else {
                // info 级 (从 debug 提到 info) — debug 默认不打印, info 上 .log 文件
                log.info("vdagent MONITORS_CONFIG sent \(width)x\(height) (\(chunkBuf.count) bytes) → fd=\(self.sockFD)")
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
    }

    private func doDisconnect() {
        if sockFD >= 0 {
            Darwin.close(sockFD)
            sockFD = -1
        }
        lastSentSize = nil
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
