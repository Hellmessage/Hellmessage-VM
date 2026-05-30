// HVMCore/SignalGuard.swift
// 加密长事务 (encrypt / decrypt / rekey) 的 SIGINT/SIGTERM 防中断 + 兜底清理.
// 第一次 Ctrl-C 打警告不打断事务; 5s 内二次 Ctrl-C 跑 atexit cleanup 后 _exit(130).
//
// 硬约束: signal handler 内只能调 async-signal-safe 函数 (write(2) / atomic / _exit),
// 不打 print / 不调 Swift API; 计时用 clock_gettime(CLOCK_MONOTONIC) 不用 Date.
// SIGKILL / abort 拦不住, 用户自负. install/uninstall 走 reentrant 计数.

import Foundation
import Darwin

public enum SignalGuard {
    private static let log = HVMLog.logger("core.signalGuard")

    /// 二次按 Ctrl-C 的窗口期 (秒). 超过窗口视为新一次"第一次"按.
    private static let secondPressWindowSec: Double = 5.0

    /// 第一次按 Ctrl-C 时打到 stderr 的警告. 必须 async-signal-safe — 走 write(2) 不走 print.
    nonisolated(unsafe) private static var warningMsg: String = "\n⚠ 加密操作进行中, 请等待结束 (再次 Ctrl-C 强制退出, 可能留残留)\n"

    // MARK: - 全局状态 (signal handler 必须 async-signal-safe; 用 sig_atomic_t)

    /// 上一次按 Ctrl-C 的 monotonic 秒. 0 = 还没按过.
    nonisolated(unsafe) private static var lastSignalSec: Int64 = 0
    /// reentrant install 计数 (避免嵌套时提前 uninstall).
    nonisolated(unsafe) private static var installCount: Int32 = 0
    /// cleanup 队列同步用 (signal 不可重入, 用 NSLock 给主路径同步).
    private static let cleanupLock = NSLock()
    nonisolated(unsafe) private static var cleanupCallbacks: [() -> Void] = []
    nonisolated(unsafe) private static var atexitRegistered = false

    /// 老 handler 备份 (uninstall 时还原).
    nonisolated(unsafe) private static var oldIntAction = sigaction()
    nonisolated(unsafe) private static var oldTermAction = sigaction()

    // MARK: - 公开 API

    /// 进程级永久忽略 SIGPIPE. 所有 entry (HVM main / hvm-cli / hvm-dbg) 启动顶部都必须调.
    /// 否则 IPC server 给已退出的 client 写响应时 write(2) 触发 SIGPIPE 杀掉 host 进程,
    /// QEMU/swtpm reparent 成 orphan 占着锁, 新 host 启不来. 装 SIG_IGN 后 write 返 EPIPE 走正常错误路径.
    /// 跟 install()/uninstall() 的加密防中断逻辑独立, 进程级永久装.
    public static func ignoreSIGPIPE() {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGPIPE, &action, nil)
    }

    /// 注册 SIGINT + SIGTERM 防中断. message 自定义; 留空走默认 "加密操作进行中 ..." 文案.
    /// 嵌套调用安全 (内部计数; 外层 install + 内层 install + 内层 uninstall + 外层 uninstall 正确).
    public static func install(message: String? = nil) {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }

        if let m = message { warningMsg = m + "\n" }

        installCount += 1
        if installCount > 1 { return }   // 已 install, 不重注

        // 重置最后按时间, 每次新事务从头计时
        lastSignalSec = 0

        var newAction = sigaction()
        newAction.__sigaction_u.__sa_handler = signalHandler
        sigemptyset(&newAction.sa_mask)
        newAction.sa_flags = 0
        sigaction(SIGINT, &newAction, &oldIntAction)
        sigaction(SIGTERM, &newAction, &oldTermAction)

        if !atexitRegistered {
            atexitRegistered = true
            atexit {
                SignalGuard.runCleanup()
            }
        }
        log.info("SignalGuard installed (depth=\(installCount))")
    }

    /// 解除 install. reentrant 计数减到 0 时真还原. 多次安全.
    public static func uninstall() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }

        guard installCount > 0 else { return }
        installCount -= 1
        if installCount > 0 { return }

        sigaction(SIGINT, &oldIntAction, nil)
        sigaction(SIGTERM, &oldTermAction, nil)
        log.info("SignalGuard uninstalled")
    }

    /// 注册兜底 cleanup. 进程正常退出 (atexit) + 二次 Ctrl-C 硬退时调用.
    /// 闭包必须无锁 / 短时. 推荐: try? FileManager.removeItem(at: tmpDir).
    public static func registerCleanup(_ block: @escaping () -> Void) {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        cleanupCallbacks.append(block)
    }

    /// 清空 cleanup 队列 (事务正常完成后调; 防 atexit 重复跑).
    public static func clearCleanup() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        cleanupCallbacks.removeAll()
    }

    // MARK: - 内部

    /// signal handler — 必须 async-signal-safe. 不分配内存, 不调 Swift 标准库.
    /// 行为: 第一次 → 警告 + 不退; 5s 内二次 → _exit(130) (atexit 自动跑 cleanup).
    private static let signalHandler: @convention(c) (Int32) -> Void = { _ in
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        let now = Int64(ts.tv_sec)
        let last = lastSignalSec

        if last != 0 && (now - last) < Int64(secondPressWindowSec) {
            // 二次按: 立刻退, atexit 跑 cleanup (POSIX 行为)
            let abortMsg = "\n✗ 二次 Ctrl-C, 强制退出\n"
            _ = abortMsg.withCString { ptr in
                write(STDERR_FILENO, ptr, strlen(ptr))
            }
            _exit(130)
        }

        // 第一次: 写警告 + 记时, 继续跑
        lastSignalSec = now
        _ = warningMsg.withCString { ptr in
            write(STDERR_FILENO, ptr, strlen(ptr))
        }
    }

    /// 跑 cleanup 队列. atexit 触发 / 主路径需要时显式调.
    /// LIFO 顺序 (最后注册的先跑, 跟 defer 直觉一致).
    private static func runCleanup() {
        cleanupLock.lock()
        let cbs = cleanupCallbacks
        cleanupCallbacks.removeAll()
        cleanupLock.unlock()

        for cb in cbs.reversed() {
            cb()
        }
    }
}
