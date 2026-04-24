// HVMBundle/BundleLock.swift
// 对 bundle/.lock 文件加 fcntl flock(LOCK_EX|LOCK_NB)
// 语义见 docs/VM_BUNDLE.md "互斥锁 (flock)"

import Foundation
import HVMCore

public final class BundleLock {
    public enum Mode: String, Sendable {
        case runtime
        case edit
    }

    /// 锁文件内记录的持有者信息, 用于诊断 (不是锁本身)
    public struct HolderInfo: Codable, Sendable {
        public var pid: Int32
        public var host: String
        public var socketPath: String
        public var mode: String
        public var since: Date
    }

    private let fd: Int32
    private let bundleURL: URL
    private var released = false

    /// 尝试抢锁. 失败抛 HVMError.bundle(.busy) 或 .lockFailed.
    /// - Parameter socketPath: 当前持有者将在何处监听 IPC (runtime 模式记录; edit 模式留空)
    public init(bundleURL: URL, mode: Mode, socketPath: String = "") throws {
        self.bundleURL = bundleURL
        let lockURL = BundleLayout.lockURL(bundleURL)

        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw HVMError.bundle(.lockFailed(reason: "open .lock failed, errno=\(errno)"))
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let saved = errno
            let holder = BundleLock.readHolder(fd: fd)
            close(fd)
            if saved == EWOULDBLOCK {
                throw HVMError.bundle(.busy(
                    pid: holder?.pid ?? 0,
                    holderMode: holder?.mode ?? "unknown"
                ))
            }
            throw HVMError.bundle(.lockFailed(reason: "flock failed, errno=\(saved)"))
        }

        self.fd = fd

        // 写入持有者信息
        let info = HolderInfo(
            pid: getpid(),
            host: ProcessInfo.processInfo.hostName,
            socketPath: socketPath,
            mode: mode.rawValue,
            since: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(info) {
            _ = ftruncate(fd, 0)
            _ = lseek(fd, 0, SEEK_SET)
            data.withUnsafeBytes { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
        }
    }

    public func release() {
        guard !released else { return }
        released = true
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }

    /// 从已打开的 .lock 文件读取持有者信息
    private static func readHolder(fd: Int32) -> HolderInfo? {
        _ = lseek(fd, 0, SEEK_SET)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        let data = Data(buf.prefix(Int(n)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HolderInfo.self, from: data)
    }

    /// 无需抢锁, 仅查看 .lock 文件里记录的持有者 (诊断用)
    public static func inspect(bundleURL: URL) -> HolderInfo? {
        let lockURL = BundleLayout.lockURL(bundleURL)
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return readHolder(fd: fd)
    }

    /// 无副作用: 用 LOCK_EX|LOCK_NB 探测锁状态, 立即释放; 用于 hvm-cli list 判断 VM 是否在跑
    public static func isBusy(bundleURL: URL) -> Bool {
        let lockURL = BundleLayout.lockURL(bundleURL)
        guard FileManager.default.fileExists(atPath: lockURL.path) else { return false }
        let fd = open(lockURL.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
