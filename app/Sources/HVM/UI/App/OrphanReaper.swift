// OrphanReaper.swift
//
// 启动时清理上一次 GUI 异常死亡 (SIGKILL / 崩溃 / 强制退出) 留下的孤儿:
//   - 孤儿 QEMU / swtpm 进程: host 子进程死了, child 被 launchd reparent (PPID=1),
//     仍在跑 — 占大量 RAM (4G+) / CPU, 阻碍后续 VM 启动. 用 SIGTERM → SIGKILL 杀掉.
//   - 残留 socket / .lock 文件: 对应 VM 的 BundleLock 不 busy 时, run/<uuid>.* 都是
//     stale, 删掉避免下次启 VM 时 QEMU bind 失败的潜在问题.
//
// 注: 老的 "kickstart socket_vmnet daemon 防 stale" 段已下线 — 桥接逻辑切到 hell-vm
//     风格新方案后, daemon 生命周期由 launchd KeepAlive 管, 不再由 HVM 主动 kickstart.
//
// 触发时机: HVMAppDelegate.applicationDidFinishLaunching, 在主窗口建立 / 列 VM 之前.
// 杜绝 "上次 HVM 崩溃 → 这次 HVM 启不起来 / 启 VM 报 socket exists" 的连锁故障.
//
// 设计:
//   - 不依赖任何 HVM 自身状态 (因为 GUI 刚启动, 还没载入 sessions / fanouts).
//   - 通过 ps -axo pid=,ppid=,command= 枚举进程, 路径匹配 + PPID==1 双条件确认孤儿.
//   - 路径匹配只匹 `Resources/QEMU/bin/{qemu-system-aarch64,swtpm}`, 不会误杀别的程序.
//   - PPID==1 = 父进程已死被 launchd 收养, 是孤儿的判定金标准 (合法运行中的 host 子
//     进程派生的 QEMU PPID 仍指向那个 host 子进程, 不会是 1).

import Foundation
import Darwin
import OSLog
import HVMCore
import HVMBundle

private let log = Logger(subsystem: "com.hellmessage.vm", category: "OrphanReaper")

enum OrphanReaper {

    /// 启动时一次性清理. 主进程同步调用 (一般 < 200ms), 不阻塞 UI 加载明显.
    static func reapOnLaunch() {
        let orphans = scanOrphans()
        if !orphans.isEmpty {
            log.warning("发现 \(orphans.count) 个孤儿 QEMU/swtpm 进程, 开始清理")
            killAndWait(orphans)
        }
        cleanStaleSockets()
    }

    // MARK: - 进程扫描

    private struct ProcInfo {
        let pid: pid_t
        let ppid: pid_t
        let cmd: String
    }

    /// 扫所有进程, 找 cmdline 含 HVM 包内 QEMU/swtpm 路径 + PPID==1 的 (孤儿).
    private static func scanOrphans() -> [ProcInfo] {
        // 用 ps 而不是 sysctl: 简单, command line 完整, 跨 macOS 版本稳定.
        // -ww: 不截断长 command line; -axo: 全部进程 + 自定义列.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axwwo", "pid=,ppid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            log.error("ps 启动失败: \(String(describing: error))")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        // 路径关键词: 任何 .app 路径下的 Resources/QEMU/bin/{qemu-system-aarch64,swtpm}.
        // /Applications/HVM.app/... 或 build/HVM.app/... 都算; 我们的 codesign id 一致,
        // 不区分位置 — 只要路径含 HVM 标志即认作 HVM 派生.
        let qemuMarker = "/Resources/QEMU/bin/qemu-system-aarch64"
        let swtpmMarker = "/Resources/QEMU/bin/swtpm"

        var orphans: [ProcInfo] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 解析: <pid> <ppid> <cmd...>
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            let cmd = String(parts[2])
            guard cmd.contains(qemuMarker) || cmd.contains(swtpmMarker) else { continue }
            // 孤儿判定: 父被 reparent 到 launchd (pid=1).
            // 合法 host 子进程派生的 QEMU 的 PPID 是 host 子进程自己, 不会是 1.
            guard ppid == 1 else { continue }
            orphans.append(ProcInfo(pid: pid, ppid: ppid, cmd: cmd))
        }
        return orphans
    }

    // MARK: - 杀进程

    private static func killAndWait(_ procs: [ProcInfo]) {
        // SIGTERM 优雅退 (QEMU 收 SIGTERM 直接 exit, swtpm 同样)
        for p in procs {
            log.info("SIGTERM pid=\(p.pid)")
            _ = kill(p.pid, SIGTERM)
        }
        // 等最多 1.5 秒
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if procs.allSatisfy({ kill($0.pid, 0) != 0 && errno == ESRCH }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // 还活着的强 kill
        for p in procs where kill(p.pid, 0) == 0 {
            log.warning("SIGTERM 后仍活, SIGKILL pid=\(p.pid)")
            _ = kill(p.pid, SIGKILL)
        }
    }

    // MARK: - 残留 socket / lock 清理

    /// 列所有 VM bundle, 对每个 BundleLock.isBusy=false 的 VM, 删 run/<uuid>.* 残留.
    /// 活的 VM (BundleLock busy) 的 socket 不动. 这层是兜底, 主要靠上面孤儿 kill.
    private static func cleanStaleSockets() {
        let vmsRoot = HVMPaths.vmsRoot
        guard let urls = try? BundleDiscovery.list(in: vmsRoot) else { return }
        let runDir = HVMPaths.runDir
        let fm = FileManager.default
        var removedCount = 0
        for u in urls {
            // 只读 config 拿 id, 不抢锁 (避免跟可能正在启的 host 子进程争锁导致它误判)
            guard let cfg = try? BundleIO.load(from: u) else { continue }
            // BundleLock busy = host 子进程仍持锁 (合法), 跳过
            if BundleLock.isBusy(bundleURL: u) { continue }
            let uuidLower = cfg.id.uuidString.lowercased()
            // 删该 UUID 的所有 run/* 残留
            let suffixes = [".sock", ".qmp", ".qmp.input.sock", ".iosurface.sock",
                             ".vdagent.sock", ".console.sock",
                             ".swtpm.sock", ".swtpm.pid"]
            for suffix in suffixes {
                let url = runDir.appendingPathComponent("\(uuidLower)\(suffix)")
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                    removedCount += 1
                }
            }
        }
        if removedCount > 0 {
            log.info("清理残留 socket / pid 文件 \(removedCount) 个")
        }
    }
}
