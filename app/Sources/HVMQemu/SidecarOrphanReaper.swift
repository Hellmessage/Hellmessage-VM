// HVMQemu/SidecarOrphanReaper.swift
// 通过 pid 文件 reap orphan sidecar 进程 (swtpm / QEMU 共用).
//
// 跟 HVM/UI/App/OrphanReaper 的边界:
//   - HVM 内的 `OrphanReaper.reapOnLaunch` 在 **GUI 启动时一次性** 扫所有进程 (ps -axwwo
//     + PPID==1 判定 + 路径含 HVM bundle), 兜底清理上次 GUI 异常退留下的所有 orphan.
//   - 本类是 **每次 sidecar 启动前** 按 pid 文件精准 reap, 适配 host 子进程被 SIGKILL /
//     之前的 SIGPIPE 杀掉留下的 orphan; CLI 启动 VM (无 GUI 启动那个全局 scan) 路径必须有
//     这一层. 两者互补, 不重复.
//
// 触发场景:
//   - host 进程被 SIGKILL / SIGPIPE (修前) / OOM 等突发信号杀掉, 没有走 tearDown 路径
//   - Swift Process() spawn 的 swtpm / QEMU 子进程 reparent 到 launchd 成 orphan, 仍在跑
//   - orphan 占着 tpm/.lock NVRAM 锁 + run/<id>.qmp socket + 磁盘 fd, 让新 host 启不来
//
// 修复策略:
//   - 新 host 起 sidecar 前调一次, 按 pid 文件抓 orphan, SIGTERM + 短 wait + SIGKILL 兜底
//   - 进程名校验 (kinfo_proc.p_comm) 防 pid 重用误杀
//   - kill -0 ESRCH 判定已死, 立即返
//
// 限制:
//   - kp_proc.p_comm 截断到 16 字符 (MAXCOMLEN+1) — "swtpm" / "qemu-system-aar" 都能匹配,
//     更长的名字需要 proc_pidpath, 暂不需要
//   - 我们不是 orphan 的父进程, 不能 waitpid; 用 kill(pid, 0) ESRCH 100ms poll 等死

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

        // 2. kill(pid, 0) 测活. ESRCH = 进程已不存在 (常态), EPERM = 同 uid 不可访问 (罕见, 保守视为活)
        if kill(pid, 0) != 0 {
            if errno == ESRCH {
                return    // 老进程已死, 没什么要 reap 的
            }
            // EPERM 等其他 errno: 进程可能还在, 继续走 reap 路径 (kill 信号仍可能起作用)
        }

        // 3. 进程名校验, 防 pid 重用. 拿不到名字 → 保守不 reap (宁可不杀, 不误杀)
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

        // 4. SIGTERM 后 poll 200ms 等进程退出 (10ms × 20). swtpm 关 NVRAM + flush 通常 < 50ms
        for _ in 0..<20 {
            usleep(10_000)   // 10ms
            if kill(pid, 0) != 0, errno == ESRCH {
                log.info("reaper: orphan pid=\(pid) 已退 (SIGTERM)")
                return
            }
        }

        // 5. SIGKILL 兜底. swtpm 拒绝退 (硬卡 / 死锁) 时必须强杀, 否则新 sidecar 起不来
        log.warning("reaper: orphan pid=\(pid) SIGTERM 200ms 未退, 发送 SIGKILL")
        _ = kill(pid, SIGKILL)
        for _ in 0..<20 {
            usleep(10_000)
            if kill(pid, 0) != 0, errno == ESRCH {
                log.info("reaper: orphan pid=\(pid) 已退 (SIGKILL)")
                return
            }
        }
        // 200ms 后还活着: zombie / 其他 uid (不可能, 同用户启的) / kernel hang.
        // log 但不抛 — 让 sidecar 启动正常往下走 (大概率仍会因占资源 fail, 此时给 user 明确报错)
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
