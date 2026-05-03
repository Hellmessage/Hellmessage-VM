// HVMScmRecvTests.swift
// HVMScmRecv 是 C 胶水, Swift 不能直接调 cmsg 宏. 这里走 socketpair + sendmsg/recvmsg
// round-trip, 验证:
//   - 单 fd 透传成功 (out_fd != -1)
//   - 0 fd 时 out_fd == -1, payload 仍正常
//   - 多 fd ancillary (协议违规) 被拦截, 返回 -1 errno=EPROTO
//
// 不测的:
//   - EINTR 重试 (依赖 kernel 调度模拟困难, C 实现已 retry)
//   - 缓冲溢出 (bufsize=0, 调用方应自行避免)

import XCTest
import Darwin
@testable import HVMScmRecv

final class HVMScmRecvTests: XCTestCase {

    // MARK: - 工具: 在 socketpair 上 sendmsg 一份带 N 个 fd 的消息

    /// 返回 (sender, receiver) socketpair fd 对.
    private func makeSocketPair() -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair 失败 errno=\(errno)")
        return (fds[0], fds[1])
    }

    /// 通过 sender 发送 payload + N 个 attachedFds (ancillary SCM_RIGHTS).
    private func sendWithFds(sender: Int32, payload: [UInt8], attachedFds: [Int32]) {
        var iov = iovec()
        let payloadCopy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: payload.count)
        _ = payloadCopy.initialize(from: payload)
        iov.iov_base = UnsafeMutableRawPointer(payloadCopy.baseAddress!)
        iov.iov_len = payload.count

        let fdsBytes = attachedFds.count * MemoryLayout<Int32>.size
        let cmsgSpace = Int(CMSG_SPACE(socklen_t(fdsBytes)))
        let cmsgBuf = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace,
                                                       alignment: MemoryLayout<cmsghdr>.alignment)
        memset(cmsgBuf, 0, cmsgSpace)

        var msg = msghdr()
        withUnsafeMutablePointer(to: &iov) { iovPtr in
            msg.msg_iov = iovPtr
            msg.msg_iovlen = 1
            if !attachedFds.isEmpty {
                msg.msg_control = cmsgBuf
                msg.msg_controllen = socklen_t(cmsgSpace)
                let cmsg = cmsgBuf.assumingMemoryBound(to: cmsghdr.self)
                cmsg.pointee.cmsg_len = socklen_t(CMSG_LEN(socklen_t(fdsBytes)))
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                let dataPtr = CMSG_DATA(cmsg).assumingMemoryBound(to: Int32.self)
                for (i, fd) in attachedFds.enumerated() { dataPtr[i] = fd }
            }
            let n = sendmsg(sender, &msg, 0)
            XCTAssertGreaterThan(n, 0, "sendmsg 失败 errno=\(errno)")
        }
        cmsgBuf.deallocate()
        payloadCopy.deallocate()
    }

    /// CMSG_SPACE / CMSG_LEN 对 C 宏的 Swift wrapper. socklen_t 和 size_t 在 macOS 上是 UInt32 / Int.
    private func CMSG_SPACE(_ length: socklen_t) -> Int {
        // align(cmsghdr) + align(length); 对齐到 sizeof(uint32_t)
        let hdr = (MemoryLayout<cmsghdr>.size + 3) & ~3
        let len = (Int(length) + 3) & ~3
        return hdr + len
    }
    private func CMSG_LEN(_ length: socklen_t) -> Int {
        let hdr = (MemoryLayout<cmsghdr>.size + 3) & ~3
        return hdr + Int(length)
    }
    private func CMSG_DATA(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
        let raw = UnsafeMutableRawPointer(cmsg)
        let aligned = (MemoryLayout<cmsghdr>.size + 3) & ~3
        return raw.advanced(by: aligned)
    }

    // MARK: - cases

    /// payload 无 fd 时 out_fd = -1, 字节数 = payload size.
    func testRecvNoFd() {
        let (s, r) = makeSocketPair()
        defer { close(s); close(r) }

        let payload: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        sendWithFds(sender: s, payload: payload, attachedFds: [])

        var buf = [UInt8](repeating: 0, count: 64)
        var outFd: Int32 = 0
        let n = buf.withUnsafeMutableBufferPointer { bp in
            hvm_scm_recv_msg(r, bp.baseAddress, bp.count, &outFd)
        }
        XCTAssertEqual(n, 4)
        XCTAssertEqual(Array(buf.prefix(4)), payload)
        XCTAssertEqual(outFd, -1, "无 ancillary 时 out_fd 应为 -1")
    }

    /// 单 fd 正常透传, payload + fd 都到位; 收到的 fd 是 host 端 dup, close 不影响 sender 那边.
    func testRecvSingleFd() {
        let (s, r) = makeSocketPair()
        defer { close(s); close(r) }

        // 拿一个真实可识别的 fd (临时文件)
        let tmp = "/tmp/hvm-scm-test-\(UUID().uuidString)"
        let fileFd = open(tmp, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fileFd, 0, "open tmp file 失败 errno=\(errno)")
        defer { close(fileFd); unlink(tmp) }

        sendWithFds(sender: s, payload: [0x01, 0x02], attachedFds: [fileFd])

        var buf = [UInt8](repeating: 0, count: 64)
        var outFd: Int32 = -1
        let n = buf.withUnsafeMutableBufferPointer { bp in
            hvm_scm_recv_msg(r, bp.baseAddress, bp.count, &outFd)
        }
        XCTAssertEqual(n, 2)
        XCTAssertGreaterThanOrEqual(outFd, 0, "应收到 fd")
        XCTAssertNotEqual(outFd, fileFd, "收到的应是 dup 后的新 fd, 不是原 fd")
        close(outFd)
    }

    /// 多 fd ancillary 是协议违规. 实现应静默关闭多余 fd 并返回 -1, errno=EPROTO.
    func testRecvMultipleFdsRejected() {
        let (s, r) = makeSocketPair()
        defer { close(s); close(r) }

        let tmp1 = "/tmp/hvm-scm-test-\(UUID().uuidString)"
        let tmp2 = "/tmp/hvm-scm-test-\(UUID().uuidString)"
        let fd1 = open(tmp1, O_RDWR | O_CREAT, 0o600)
        let fd2 = open(tmp2, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd1, 0)
        XCTAssertGreaterThanOrEqual(fd2, 0)
        defer { close(fd1); close(fd2); unlink(tmp1); unlink(tmp2) }

        sendWithFds(sender: s, payload: [0xFF], attachedFds: [fd1, fd2])

        var buf = [UInt8](repeating: 0, count: 64)
        var outFd: Int32 = 0
        let n = buf.withUnsafeMutableBufferPointer { bp in
            hvm_scm_recv_msg(r, bp.baseAddress, bp.count, &outFd)
        }
        XCTAssertEqual(n, -1, "多 fd 应被拦截")
        XCTAssertEqual(errno, EPROTO, "errno 应为 EPROTO, 实际 \(errno)")
    }
}
