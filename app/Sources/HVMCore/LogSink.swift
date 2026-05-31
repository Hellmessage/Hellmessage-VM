// HVMCore/LogSink.swift
// 把 os.Logger 的日志异步 mirror 到 ~/Library/Application Support/HVM/logs/<yyyy-MM-dd>.log,
// 按天 rotate, 保留 14 天. 周期 OSLogStore.getEntries 拉本进程 OSLogEntry, 过滤 subsystem 写当日文件.
//
// 必须是 actor (非 MainActor): getEntries 是同步阻塞 syscall (50-200ms 持 unified logging 锁),
// 跑在主线程会 starve MTKView draw → framebuffer 周期卡顿. actor 化后跑 cooperative pool, 主线程零阻塞.
// scope=.currentProcessIdentifier: 短命 hvm-cli 不落文件 (其 stdout 已够看), 只长命 GUI/VMHost 持续落盘.

import Foundation
import os
import OSLog

/// 日志文件 sink. actor 隔离串行化 fileHandle / lastPosition / currentDay 等可变状态;
/// 跑在 cooperative thread pool, 不占主线程.
public actor LogSink {
    public static let shared = LogSink()

    /// 日志保留天数, 超过的 .log 文件自动删
    public static let retentionDays: Int = 14
    /// 轮询间隔
    private static let pollIntervalSec: UInt64 = 5

    private var started = false
    private var pollTask: Task<Void, Never>?
    /// 全局日志输出开关 — 受 LoggingPreferences 控制. 默认 true.
    /// false 时 pollOnce 仅推 lastPosition 不写文件, 关 fileHandle.
    private var enabled: Bool = true

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

    /// 启动 sink. 幂等. 由 HVMLog.logger() 触发.
    /// initialEnabled 由调用方传入 — LogSink 是 actor, 不直接读 @MainActor 的 LoggingPreferences.
    public func start(initialEnabled: Bool = true) {
        if !started {
            enabled = initialEnabled
        }
        guard !started else { return }
        started = true

        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            // 取不到 store (sandbox 限制? 旧 macOS?) — 文件 sink 静默不工作, os.Logger 仍正常
            return
        }
        // 起点取当下, 避免回放本进程之前的所有 log
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

    /// 切换全局日志开关. 关闭时关 fileHandle, pollOnce 仅推 lastPosition 不写文件.
    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if !value {
            try? fileHandle?.synchronize()
            try? fileHandle?.close()
            fileHandle = nil
        }
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
        // 开关关闭: 仅把 lastPosition 推到 now, 防止开启后回放关闭期间堆积的历史日志
        if !enabled {
            lastPosition = store.position(date: Date())
            return
        }
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
