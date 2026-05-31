// HVMCore/ProcessFileLock.swift
// 通用进程级 flock 持有者 (tray 归属协调用; 与 bundle 专用的 BundleLock 区分).
//
// 持有: init? 成功即 LOCK_EX|LOCK_NB 拿到锁, 持到 release()/进程退出 (flock 随 fd 关闭/进程死自动释放).
// 探测: isHeld(path:) 无副作用判断锁是否被别的进程占着.
//
// flock(2) 只在本机 inode 上互斥, 跨主机 (NFS/SMB) 不可靠 — tray 协调只在单机, 无此问题.

import Foundation

public final class ProcessFileLock: @unchecked Sendable {
    private var fd: Int32
    private var released = false

    /// 尝试独占持有 path. 已被别的进程持有 → 返 nil. 目录会按需创建.
    public init?(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    public func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }

    /// 无副作用探测: path 是否正被某进程独占持有.
    /// 注意 flock 锁在 open file description 上, 同进程对同一文件的不同 open() 也会互斥 —
    /// 故 isHeld 只该由"不持有该锁的进程"调 (本设计: VMHost 探 gui-owner, GUI 探/不探 tray-leader,
    /// 各进程从不探自己持有的锁), 不会误判自身.
    public static func isHeld(path: URL) -> Bool {
        let fd = open(path.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false   // 拿得到 = 没人持有
        }
        return true        // EWOULDBLOCK = 被别的进程持有
    }
}
