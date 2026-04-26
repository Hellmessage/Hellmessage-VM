// HVMBundle/BundleLock.swift
// 对 bundle/.lock 文件加 fcntl flock(LOCK_EX|LOCK_NB)
// 语义见 docs/VM_BUNDLE.md "互斥锁 (flock)"
//
// 跨主机限制: flock(2) 只在本机 inode 上互斥. bundle 若放在 NFS / SMB 共享卷上,
// 两台主机可同时拿到锁, 触发 docs 里"一 bundle 同时只能被一个进程打开"的硬约束失效.
// 我们在锁初始化时 statfs 探测, 非本地卷给一次 warning (不强禁), 让用户自担风险.

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

    private static let log = HVMLog.logger("bundle.lock")

    /// 尝试抢锁. 失败抛 HVMError.bundle(.busy) 或 .lockFailed.
    /// - Parameter socketPath: 当前持有者将在何处监听 IPC (runtime 模式记录; edit 模式留空)
    public init(bundleURL: URL, mode: Mode, socketPath: String = "") throws {
        self.bundleURL = bundleURL
        let lockURL = BundleLayout.lockURL(bundleURL)

        // 跨主机互斥检查: bundle 落在非 apfs/hfs 卷 (NFS/SMB/exFAT/...) 上 flock 不可靠
        Self.warnIfNonLocalVolume(at: bundleURL)

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

    // MARK: - 卷类型探测

    /// 进程级 dedup: 同一 bundleURL 只 warn 一次, 避免每次抢锁刷屏.
    /// nonisolated(unsafe) + NSLock 手动保护 — Swift 6 不让 mutable static 默认裸跑.
    nonisolated(unsafe) private static var warnedPaths: Set<String> = []
    private static let warnedLock = NSLock()

    /// statfs 探测 bundle 所在卷的文件系统类型, 非本地 (apfs/hfs) 时 warning.
    /// 不强禁 — 用户可能有合理理由 (例如 bundle 实际在挂载点下但不会跨主机争抢).
    private static func warnIfNonLocalVolume(at bundleURL: URL) {
        var fs = statfs()
        guard statfs(bundleURL.path, &fs) == 0 else { return }

        // f_fstypename 是 fixed-size C array, 转字符串
        let typeName: String = withUnsafeBytes(of: &fs.f_fstypename) { raw in
            let cstr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: cstr)
        }

        // apfs / hfs / hfs+ 都是本地; 其他 (nfs, smbfs, exfat, msdos 等) 跨主机不可靠
        let localTypes: Set<String> = ["apfs", "hfs"]
        guard !localTypes.contains(typeName.lowercased()) else { return }

        warnedLock.lock()
        let key = bundleURL.standardizedFileURL.path
        let already = warnedPaths.contains(key)
        if !already { warnedPaths.insert(key) }
        warnedLock.unlock()
        guard !already else { return }

        Self.log.warning("""
            bundle 在非本地卷上 (fstype=\(typeName, privacy: .public), path=\(bundleURL.path, privacy: .public)).
            fcntl flock 只在本机 inode 上互斥, 跨主机不可靠;
            两台主机同时打开同一 bundle 会破坏 disks/auxiliary 数据.
            建议把 .hvmz 移到本地 APFS 卷.
            """)
    }
}
