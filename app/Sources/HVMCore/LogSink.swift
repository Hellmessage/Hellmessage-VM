// HVMCore/LogSink.swift
// 把 os.Logger 的日志异步 mirror 到 ~/Library/Application Support/HVM/logs/<yyyy-MM-dd>.log,
// 按天 rotate, 保留 14 天 (docs/ARCHITECTURE.md "日志").
//
// 实现路径: 用 OSLogStore.getEntries 周期性 (5s) 拉取本进程的 OSLogEntry, 过滤 subsystem,
// 写入当日文件. 优点:
//   - 不改 HVMLog.logger API (依然返 os.Logger), 现有 call site 全部不动
//   - Console.app 的体验保留 (subsystem == com.hellmessage.vm)
//   - 用户级日志落盘可被 grep / hvm-cli logs 等工具读
//
// 缺陷 / 取舍:
//   - poll 间隔 5s, 极端情况下日志 latency 5s. 关进程时 flush 一次最后窗口
//   - OSLogStore.scope: .currentProcessIdentifier — 跨进程 (例如 hvm-cli 短命进程) 不进文件
//     这是对的: hvm-cli 自己的 stdout 已经够看, 长期落盘只需要 GUI 主进程 / VMHost 持续运行的
//
// 启动方式: HVMLog.logger 第一次调用时 lazy 启动 LogSink.shared (在 HVMLog 内部).
// 进程退出时通过 atexit 拉一次最终 flush — 主流程崩溃可能丢最后 5s, 但崩溃路径下我们已经
// 通过 os.Logger 把信息写到 OSLogStore 持久化了, 用户事后可用 `log show` 拉.

import Foundation
import os
import OSLog

/// 日志文件 sink, MainActor 隔离 (rotateIfNeeded 写文件不应跨线程乱).
@MainActor
public final class LogSink {
    public static let shared = LogSink()

    /// 日志保留天数, 超过的 .log 文件自动删
    public static let retentionDays: Int = 14
    /// 轮询间隔. OSLogStore.getEntries 是同步阻塞 syscall, 持系统级 unified logging
    /// 锁; 长跑进程 (GUI / VMHost) entries 多, 单次扫描 50-200ms, 期间 main thread
    /// 上的 os.Logger 调用会短暂阻塞 → MTKView draw 调度被 starve → 用户看到 framebuffer
    /// 周期卡顿. 调到 30s: 文件 .log 滞后 30s 用户接受 (紧急排查用 Console.app 看实时
    /// OSLog), 卡顿频率从 12/min 降到 2/min, 单次 spike 被 ProMotion displayLink 平滑掉.
    private static let pollIntervalSec: UInt64 = 30

    private var started = false
    private var pollTask: Task<Void, Never>?

    /// 当前正在写的文件
    private var fileHandle: FileHandle?
    /// 当前文件对应的"当天 0 点" Date, 用于判断是否需 rotate
    private var currentDay: Date = .distantPast

    /// 上次 poll 已读到的最新位置 (OSLogPosition), 下次 poll 从这继续
    private var lastPosition: OSLogPosition?

    /// 本进程 OSLogStore 实例; 取不到 (例如 sandbox 限制) 就放弃文件 sink, os.Logger 仍正常
    private var store: OSLogStore?

    private static let logsDir: URL = {
        // 内联避免循环依赖 HVMPaths (LogSink 在 HVMCore 内, HVMPaths 也在 HVMCore)
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HVM/logs", isDirectory: true)
    }()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static let tsFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private init() {}

    /// 启动 sink. 幂等. 由 HVMLog.logger() 触发, 用户不必直接调.
    public func start() {
        guard !started else { return }
        started = true

        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            // 取不到 store (sandbox 限制? 旧 macOS?) — 文件 sink 静默不工作, os.Logger 仍正常
            return
        }
        // 起点: 当下时刻 (避免回放本进程之前的所有 log, 包括 system framework 噪音)
        lastPosition = store?.position(date: Date())

        pollTask = Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    /// 强制 flush 一次 (退出前最后保存)
    public func flushAndStop() async {
        await pollOnce()
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 轮询

    nonisolated private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.pollIntervalSec * 1_000_000_000)
            await self.pollOnce()
        }
    }

    private func pollOnce() async {
        guard let store, let pos = lastPosition else { return }
        // 过滤 subsystem == HVMLog.subsystem
        let predicate = NSPredicate(format: "subsystem == %@", HVMLog.subsystem)

        let entries: AnySequence<OSLogEntry>
        do {
            entries = try store.getEntries(at: pos, matching: predicate)
        } catch {
            return
        }

        for raw in entries {
            guard let entry = raw as? OSLogEntryLog else { continue }
            writeLine(entry: entry)
        }
        // 推进到当下, 下次 poll 不重读
        lastPosition = store.position(date: Date())
    }

    private func writeLine(entry: OSLogEntryLog) {
        rotateIfNeeded(now: entry.date)
        guard let fh = fileHandle else { return }
        let ts = Self.tsFmt.string(from: entry.date)
        let level = levelString(entry.level)
        let line = "\(ts) [\(level)] [\(entry.category)] \(entry.composedMessage)\n"
        if let data = line.data(using: String.Encoding.utf8) {
            try? fh.write(contentsOf: data)
        }
    }

    private func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "?"
        case .debug:     return "DBG"
        case .info:      return "INF"
        case .notice:    return "NOTE"
        case .error:     return "ERR"
        case .fault:     return "FAULT"
        @unknown default: return "?"
        }
    }

    private func rotateIfNeeded(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        if today == currentDay, fileHandle != nil { return }

        // 关旧, 开新
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        try? FileManager.default.createDirectory(at: Self.logsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let url = Self.logsDir.appendingPathComponent("\(Self.dayFmt.string(from: today)).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                            attributes: [.posixPermissions: 0o644])
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            fileHandle = fh
        }
        currentDay = today
        gcOldLogs(beforeDay: today)
    }

    /// 删 retentionDays 之前的 .log 文件
    private func gcOldLogs(beforeDay today: Date) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: today)
            ?? today
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.logsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries where url.pathExtension == "log" {
            // 文件名格式 yyyy-MM-dd.log, 直接 parse 比读 attribute 更准
            let stem = url.deletingPathExtension().lastPathComponent
            guard let day = Self.dayFmt.date(from: stem) else { continue }
            if day < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
