// HVMEncryption/SwtpmKeyHelper.swift
// 给 swtpm 子进程注入 32 字节 NVRAM 加密 key. 走 stdin (fd=0) + Pipe, 不落盘.
//
// 设计稿 docs/v3/ENCRYPTION.md v2.3 D10.
//
// 流程 (启动加密 Win VM 时):
//   1. HVM 主进程派生 swtpm-key (HKDF from master, 32 字节 binary)
//   2. SwtpmKeyHelper.makeInjector(key:) 创建 Pipe
//   3. 调用方设 process.standardInput = injector.pipeReadHandle
//   4. 调用方 argv 加 ["--key", SwtpmKeyHelper.argumentValue]
//   5. process.run() 启动 swtpm
//   6. injector.flush() 写 32 字节到 pipe + close write 端
//   7. swtpm 读完 fd=0 后用 key 加密 NVRAM state (mode=aes-256-cbc)
//
// 关键: swtpm 不像 LUKS — format=binary 接受任意 32 字节, 不要求 UTF-8.
// PR-5 D13 base64 编码限制不适用本路径.
//
// 安全:
//   - key 不落盘 (Pipe 是 anonymous, 走内核内存)
//   - swtpm 读完后 fd 自动 close (Foundation Pipe 行为)
//   - HVM 主进程 flush() 后立即 close write 端, key 字节随 ARC 释放
//
// 不做:
//   - 走 file= 形式 (会落盘, 不如 fd= 直接)
//   - mode=aes-cbc (老 128 bit AES, 没必要)
//   - format=hex (str 编码低效)

import Foundation
import CryptoKit
import HVMCore

public enum SwtpmKeyHelper {
    /// swtpm `--key` 字段值. 调用方直接挂到 argv.
    /// fd=0 = 从 stdin 读; mode=aes-256-cbc; format=binary (32 字节 raw bytes); remove=false (不删 fd).
    public static let argumentValue = "fd=0,mode=aes-256-cbc,format=binary,remove=false"

    /// 准备 swtpm key 注入. 返回 Injector, 调用方:
    ///   - 设 process.standardInput = injector.pipeReadHandle
    ///   - process.arguments += ["--key", SwtpmKeyHelper.argumentValue]
    ///   - try process.run()
    ///   - try injector.flush()  // 写 key 到 pipe 然后 close
    public static func makeInjector(key: SymmetricKey) -> Injector {
        Injector(key: key)
    }

    /// 走 Pipe 把 32 字节 swtpm-key 透传给 swtpm 子进程的 stdin.
    public final class Injector: @unchecked Sendable {
        /// 喂给 Foundation Process.standardInput. swtpm 读完后 EOF, swtpm 自动 close.
        public let pipeReadHandle: FileHandle
        private let writeHandle: FileHandle
        private let keyBytes: Data
        private var flushed = false
        private let lock = NSLock()

        fileprivate init(key: SymmetricKey) {
            let pipe = Pipe()
            self.pipeReadHandle = pipe.fileHandleForReading
            self.writeHandle = pipe.fileHandleForWriting
            self.keyBytes = key.withUnsafeBytes { Data($0) }
        }

        /// process.run() 之后调. 写 32 字节 + close write 端 (swtpm 读完 EOF).
        /// 多次调用安全 (idempotent).
        public func flush() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !flushed else { return }
            flushed = true
            try writeHandle.write(contentsOf: keyBytes)
            try writeHandle.close()
        }

        deinit {
            // 兜底: 调用方忘了 flush 也不要让 fd 泄漏 (但不写 key, swtpm 会 hang 等 EOF)
            try? writeHandle.close()
        }
    }
}
