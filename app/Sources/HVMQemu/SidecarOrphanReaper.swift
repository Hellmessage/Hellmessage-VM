// HVMQemu/SidecarOrphanReaper.swift
// 每次 sidecar (swtpm / QEMU) 启动前按 pid 文件精准 reap orphan.
// (跟 GUI 启动时一次性全局扫的 OrphanReaper 互补: CLI 启 VM 无全局 scan, 必须有这层.)
//
// 触发: host 被 SIGKILL / OOM 等突发信号杀掉没走 tearDown, 子进程 reparent 到 launchd 成
// orphan 仍在跑, 占着 NVRAM 锁 / qmp socket / 磁盘 fd 让新 host 启不来.
// 策略: SIGTERM + 短 wait + SIGKILL 兜底; 进程名校验 (kinfo_proc.p_comm) 防 pid 重用误杀.
// 限制: p_comm 截断到 16 字符; 非父进程不能 waitpid, 用 kill(pid,0) ESRCH poll 等死.

import Foundation
import Darwin
import HVMCore

public enum SidecarOrphanReaper {
    private static let log = HVMLog.logger("qemu.sidecarOrphanReaper")

    /// 通过 pid 文件抓老 sidecar orphan 并杀掉.
    /// 调用时机: 新 sidecar 启动前, FSCleanup 清 pid file 之前.
    /// - Parameter pidFile: sidecar 自己写的 pid 文件路径 (e.g. run/<id>.swtpm.pid)
    /// - Parameter expectedNamePrefix: 进程名前缀, 防 pid 重用误杀 (e.g. "swtpm" / "qemu-system")
    ///   要求是 kinfo_proc.p_comm (16 字符截断) 的前缀
    public static func reapByPidFile(pidFile: URL, expectedNamePrefix: String) {
        // 1. 读 pid file. 不存在 / 不可读 / 解析失败 → 视为无 orphan, 静默返
        guard let data = try? Data(contentsOf: pidFile),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 1 else {
            return
        }

        // 2. kill(pid, 0) 测活. ESRCH = 已死 (常态); 其他 errno 保守视为活继续 reap
        if kill(pid, 0) != 0 {
            if errno == ESRCH {
                return
            }
        }

        // 3. 进程名校验防 pid 重用. 拿不到名字保守不 reap
        guard let comm = processComm(pid: pid) else {
            log.warning("reaper: pid=\(pid) 拿不到进程名 (可能刚死), 跳过 reap")
            return
        }
        guard comm.hasPrefix(expectedNamePrefix) else {
            log.warning("reaper: pid=\(pid) 进程名 '\(comm, privacy: .public)' != '\(expectedNamePrefix, privacy: .public)', 跳过 (pid 已被复用)")
            return
        }

        log.warning("reaper: 发现 orphan \(expectedNamePrefix, privacy: .public) pid=\(pid), 发送 SIGTERM")
        _ = kill(pid, SIGTERM)

        // 4. SIGTERM 后 poll 200ms 等退出 (swtpm 关 NVRAM + flush 通常 < 50ms)
        for _ in 0..<20 {
            usleep(10_000)   // 10ms
            if kill(pid, 0) != 0, errno == ESRCH {
                log.info("reaper: orphan pid=\(pid) 已退 (SIGTERM)")
                return
            }
        }

        // 5. SIGKILL 兜底 (swtpm 硬卡时必须强杀, 否则新 sidecar 起不来)
        log.warning("reaper: orphan pid=\(pid) SIGTERM 200ms 未退, 发送 SIGKILL")
        _ = kill(pid, SIGKILL)
        for _ in 0..<20 {
            usleep(10_000)
            if kill(pid, 0) != 0, errno == ESRCH {
                log.info("reaper: orphan pid=\(pid) 已退 (SIGKILL)")
                return
            }
        }
        // 200ms 后还活着 (zombie / kernel hang): log 但不抛, 让 sidecar 启动往下走 (失败时给 user 报错)
        log.error("reaper: orphan pid=\(pid) SIGKILL 后仍未退 (zombie / 权限问题); sidecar 启动可能失败")
    }

    // MARK: - 进程名查询

    /// 通过 sysctl KERN_PROC_PID 拿 kinfo_proc.kp_proc.p_comm (16 字符截断, 不含路径).
    /// 拿不到返 nil (进程已死 / 权限不够 / sysctl 失败).
    private static func processComm(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.stride
        var info = kinfo_proc()
        let ret = withUnsafeMutablePointer(to: &info) { infoPtr -> Int32 in
            mib.withUnsafeMutableBufferPointer { mibPtr in
                sysctl(mibPtr.baseAddress, u_int(mibPtr.count),
                       infoPtr, &size,
                       nil, 0)
            }
        }
        guard ret == 0, size > 0 else { return nil }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cptr in
                String(cString: cptr)
            }
        }
    }
}
