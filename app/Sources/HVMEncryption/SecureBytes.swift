// HVMEncryption/SecureBytes.swift
// 安全字节缓冲: mlock 防 swap + memset_s 清零销毁. 用于 MasterKey / SubKeySet.
//
// 边界: root 攻击者直读 process memory mlock 防不住; mlock 仅防 narrow 的 "swap dump
// 已搞到但 host root 没拿到" 场景. memset_s 防编译器把 secure-zero 优化掉.
//
// 实现: calloc 零初始化 → mlock (失败仅 warn, 有些系统 ulimit 限容量) → deinit memset_s + munlock + free.
// 限制: 调用方在 withBytes closure 内不要把 bytes 拷出 (Data/String) — 拷走即脱离保护.

import Foundation
import Darwin
import HVMCore

/// 32 字节 (或其他长度) secure 字节缓冲. 自家 malloc + mlock + memset_s 清零销毁.
public final class SecureBytes: @unchecked Sendable {
    private static let log = HVMLog.logger("encryption.secureBytes")

    public let count: Int
    private let ptr: UnsafeMutableRawPointer
    private var locked: Bool

    /// 用 zero 字节初始化. 调用方负责 .withMutableBytes 写入.
    public init(count: Int) throws {
        guard count > 0 else {
            throw HVMError.encryption(.invalidKeyLength(got: count, expected: 1))
        }
        self.count = count
        guard let p = calloc(1, count) else {
            throw HVMError.encryption(.parseFailed(reason: "SecureBytes calloc \(count) bytes failed"))
        }
        self.ptr = p
        // 尝试 mlock — 失败 (例 RLIMIT_MEMLOCK 限制) 仅警告
        if mlock(p, count) == 0 {
            self.locked = true
        } else {
            self.locked = false
            Self.log.warning("SecureBytes mlock failed errno=\(errno) (RLIMIT_MEMLOCK?). 继续走非 lock 内存")
        }
    }

    /// 从现成 Data 拷贝建 SecureBytes (源 Data 仍在 GC 中, 不能保 secure).
    public convenience init(copying data: Data) throws {
        try self.init(count: data.count)
        self.withMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let s = src.baseAddress, let d = dst.baseAddress {
                    memcpy(d, s, data.count)
                }
            }
        }
    }

    /// 写入. closure 内拿到 mutable buffer, 写完即返回.
    public func withMutableBytes<R>(_ closure: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let buf = UnsafeMutableRawBufferPointer(start: ptr, count: count)
        return try closure(buf)
    }

    /// 读. 调用方不要把 bytes 拷贝出 closure.
    public func withBytes<R>(_ closure: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let buf = UnsafeRawBufferPointer(start: ptr, count: count)
        return try closure(buf)
    }

    deinit {
        // memset_s 防编译器优化掉清零.
        _ = memset_s(ptr, count, 0, count)
        if locked {
            _ = munlock(ptr, count)
        }
        free(ptr)
    }
}
