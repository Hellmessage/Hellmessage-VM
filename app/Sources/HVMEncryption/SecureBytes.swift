// HVMEncryption/SecureBytes.swift
// 安全字节缓冲: mlock 防 swap + memset_s 清零销毁.
// 用于 MasterKey / EncryptionKDF.SubKeySet — 防"攻击者拿到 swap dump 提 key" 边缘场景.
// (TODO #7)
//
// 实战边界:
//   - root 攻击者直接读 process memory, mlock 防不住
//   - 关机后的物理盘 swap 已被 macOS FileVault 加密 (默认开)
//   - mlock 价值: 防 "swap dump 已被搞到但 host root 没拿到" 这个 narrow 场景
//   - memset_s 防: 编译器把 secure-zero 优化掉 (普通 memset 可能被消)
//
// 实现:
//   - calloc(1, len) 分配 (确保零初始化)
//   - mlock(ptr, len) 锁页 — 失败仅 log warning, 不抛 (有些系统 ulimit 限 mlock 容量)
//   - deinit: memset_s 清零 → munlock → free
//
// 限制:
//   - Swift Data 复制走原生堆, 一旦 .withBytes closure 内调用 Data(...) 拷贝走就脱离保护
//   - 调用方自负: closure 内 不要持久化 bytes 到 Data / String / 跨边界传递

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
        try self.withMutableBytes { dst in
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
        // memset_s 防编译器优化掉清零. macOS 提供 (来自 <string.h>).
        _ = memset_s(ptr, count, 0, count)
        if locked {
            _ = munlock(ptr, count)
        }
        free(ptr)
    }
}
