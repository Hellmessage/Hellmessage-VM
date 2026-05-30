// HVMCore/VMnetBridgeProbe.swift
// 桥模式 socket_vmnet daemon 响应性轻量探测 (启 VM 前 ~200ms 内判定).
// 抓: connect 失败 (socket 孤儿 / daemon 死) + write 后 daemon 立刻断开 (拒绝服务).
// 不抓: vmnet.framework 内核侧 "bridge attach silently dead" (daemon 在 + socket 在 + write 不报错,
// 但帧不到物理 iface). user-space 无法区分, 唯一可靠判别需 sudo tcpdump; 由用户感知后点 [重启 daemon] 自救.

import Foundation
import Darwin

public enum VMnetBridgeProbe {

    public enum Result: Sendable, Equatable {
        /// daemon 响应正常: connect + write 成功, 短窗口内未断
        case ok
        /// socket 文件不存在 / 不是 unix socket — daemon 没装或孤儿
        case noSocket
        /// connect 失败 (典型 ECONNREFUSED daemon 没 listen, EAGAIN 资源不够)
        case connectFailed(errno: Int32)
        /// 探测帧写入失败 — daemon 立即断开 / 协议错配
        case writeFailed(errno: Int32)
        /// 写完帧后 daemon 立刻 hangup — 典型 daemon 异常拒绝
        case daemonHangup
    }

    /// 同步阻塞探测. 跑在专用线程, 不要在 MainActor 调.
    /// 整个探测 ~200ms 量级 (connect + write + 200ms poll-for-hangup).
    public static func probe(socketPath: String) -> Result {
        // 1. socket 类型检查 (跟 SocketPaths.isReady 同款 stat S_IFSOCK)
        var st = Darwin.stat()
        guard stat(socketPath, &st) == 0 else { return .noSocket }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { return .noSocket }

        // 2. connect (复用 UnixSocket helper)
        let fd: Int32
        do {
            fd = try UnixSocket.connect(to: socketPath, timeoutSec: 1)
        } catch let UnixSocket.Error.connectFailed(_, errno: e) {
            return .connectFailed(errno: e)
        } catch let UnixSocket.Error.openFailed(errno: e) {
            return .connectFailed(errno: e)
        } catch {
            return .connectFailed(errno: -1)
        }
        defer { Darwin.close(fd) }

        // 3. 发一帧合成 ARP probe — 测 write 路径 (socket → daemon → vmnet write call).
        //    target IP 0.0.0.0, source MAC 02:00:48:56:00:01 (locally-administered),
        //    不会撞真实硬件 MAC, 不会有任何 host 给我们 reply.
        if let err = sendProbeARPFrame(fd: fd) {
            return .writeFailed(errno: err)
        }

        // 4. 200ms 内 poll 看 daemon 是否立刻 hangup. 正常 daemon 不会 — 它会保持连接 +
        //    可能往我们发帧 (虽然实测 socket_vmnet 默认不给被动 client 转 LAN 帧).
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&pfd, 1, 200)
        if n < 0 { return .ok }  // poll 本身出错就放过, 不连累 VM 启动
        let revents = pfd.revents
        if (revents & Int16(POLLHUP)) != 0 || (revents & Int16(POLLERR)) != 0 {
            return .daemonHangup
        }
        return .ok
    }

    /// 发一帧合成 ARP request 让 daemon 检验我们的 protocol.
    /// 4-byte BE length prefix + Ethernet (14B) + ARP (28B) = 46 字节总.
    /// 失败返 errno (write 失败), 成功返 nil.
    private static func sendProbeARPFrame(fd: Int32) -> Int32? {
        let frame: [UInt8] = [
            // Ethernet: dest = ff:ff:ff:ff:ff:ff (broadcast)
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            // src = 02:00:48:56:00:01 (locally administered, 'HV' + index)
            0x02, 0x00, 0x48, 0x56, 0x00, 0x01,
            // ethertype = 0x0806 ARP
            0x08, 0x06,
            // ARP: htype=Ethernet(1), ptype=IPv4(0x0800)
            0x00, 0x01, 0x08, 0x00,
            // hlen=6, plen=4
            0x06, 0x04,
            // op = request (1)
            0x00, 0x01,
            // sender hw addr = our MAC
            0x02, 0x00, 0x48, 0x56, 0x00, 0x01,
            // sender protocol addr = 0.0.0.0 (probe, 不主张任何 IP)
            0x00, 0x00, 0x00, 0x00,
            // target hw addr = 0 (典型 request)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            // target protocol addr = 0.0.0.0
            0x00, 0x00, 0x00, 0x00,
        ]
        let length = UInt32(frame.count).bigEndian
        var packet = [UInt8](repeating: 0, count: 4 + frame.count)
        withUnsafeBytes(of: length) { lp in
            for i in 0..<4 { packet[i] = lp[i] }
        }
        for i in 0..<frame.count { packet[4 + i] = frame[i] }

        var sent = 0
        while sent < packet.count {
            let r = packet.withUnsafeBufferPointer { bp -> Int in
                return Darwin.write(fd, bp.baseAddress! + sent, packet.count - sent)
            }
            if r > 0 {
                sent += r
            } else if r < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return errno
            } else {
                return EIO
            }
        }
        return nil
    }
}
