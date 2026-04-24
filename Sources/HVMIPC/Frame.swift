// HVMIPC/Frame.swift
// length-prefixed (big-endian u32) JSON 帧收发助手
// 协议: [4B length][JSON payload]

import Foundation
import Darwin
import HVMCore

public enum Frame {
    /// 读取单个帧. 返回 nil 表示 peer 正常关闭连接. 超时 / 错误抛 HVMError.ipc.*
    public static func read(fd: Int32) throws -> Data? {
        var lenBytes = [UInt8](repeating: 0, count: 4)
        let got = try readExact(fd: fd, into: &lenBytes, count: 4)
        if got == 0 { return nil }      // EOF 在起始处 = 正常关闭
        if got < 4 {
            throw HVMError.ipc(.readFailed(reason: "truncated length prefix"))
        }
        let len = (UInt32(lenBytes[0]) << 24) |
                  (UInt32(lenBytes[1]) << 16) |
                  (UInt32(lenBytes[2]) << 8)  |
                  (UInt32(lenBytes[3]))
        guard len > 0, len < 16 * 1024 * 1024 else {
            throw HVMError.ipc(.readFailed(reason: "invalid frame length: \(len)"))
        }
        var payload = [UInt8](repeating: 0, count: Int(len))
        let n = try readExact(fd: fd, into: &payload, count: Int(len))
        guard n == Int(len) else {
            throw HVMError.ipc(.readFailed(reason: "truncated payload, got \(n) of \(len)"))
        }
        return Data(payload)
    }

    /// 写一个帧
    public static func write(fd: Int32, payload: Data) throws {
        let len = UInt32(payload.count)
        var header: [UInt8] = [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8)  & 0xFF),
            UInt8(len & 0xFF),
        ]
        try writeAll(fd: fd, buf: &header, count: 4)
        var bytes = [UInt8](payload)
        try writeAll(fd: fd, buf: &bytes, count: bytes.count)
    }

    // MARK: - 低层

    private static func readExact(fd: Int32, into buf: inout [UInt8], count: Int) throws -> Int {
        var total = 0
        while total < count {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: total), count - total)
            }
            if n == 0 {
                return total       // EOF
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw HVMError.ipc(.readFailed(reason: "read errno=\(errno)"))
            }
            total += n
        }
        return total
    }

    private static func writeAll(fd: Int32, buf: inout [UInt8], count: Int) throws {
        var written = 0
        while written < count {
            let n = buf.withUnsafeBufferPointer { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw HVMError.ipc(.writeFailed(reason: "write errno=\(errno)"))
            }
            written += n
        }
    }
}
