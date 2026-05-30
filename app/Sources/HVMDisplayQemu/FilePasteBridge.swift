// HVMDisplayQemu/FilePasteBridge.swift
//
// host → guest 文件粘贴桥.
//
// 流程:
//   GUI 主进程 framebuffer view 拦 Cmd+V → 读 NSPasteboard file URLs
//   → IPC clipboard.paste-files 到 VMHost 子进程
//   → VMHost 子进程内 FilePasteBridge.handlePasteFiles(urls)
//   → 每个 url 串行: vdagent.sendFileXferStart → 等 CAN_SEND_DATA → 流 chunks → 等 SUCCESS
//   → 返回成功/跳过/失败汇总, VMHost 回 IPC 响应, GUI 进程发原生 UNUserNotification
//
// 跟 PasteboardBridge (文本剪贴板) 平行存在:
//   - 同一 VdagentClient 实例, 不冲突 (vdagent.queue 串行 writes)
//   - PasteboardBridge 只关心 onClipboardTextReceived callback
//   - FilePasteBridge 只关心 onFileXferStatus callback
//   - 两条 callback 是不同 slot, 互不抢
//
// 同步实现, NOT async/await:
//   实测 IPC handler 里 await `Task.sleep` (在 withTaskGroup 中) 永远不 fire — Task 调度
//   被 IPC dispatch 的 `sem.wait()` GCD 线程 + @MainActor Task 跨界栈卡住 (调试日志 "等
//   CAN_SEND_DATA" 之后 90s 无动静). 改成纯 DispatchSemaphore.wait(timeout:) 直接走 kernel
//   timer, 跟 Swift Concurrency 调度解耦, 也避免 cooperative pool 饥饿.
//   整 pipeline 包在 Task.detached 里, await 一次拿结果即可 — 不与 main actor 抢调度.
//
// 边界:
//   - 文件夹: skip + 通知 "暂不支持"
//   - 单文件 > 4 GiB: skip (跟 SPICE 协议 + QGA 一致)
//   - guest 未装 spice-vdagent: 等 CAN_SEND_DATA 30s 超时 → 报错
//   - 串行不并发: vdagent socket 单 client + SPICE 协议 chunks 不可 interleave

import Foundation
import Darwin
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "FilePaste")

public final class FilePasteBridge: @unchecked Sendable {

    /// 单文件 4 GiB 软上限. SPICE FILE_XFER_DATA size 字段是 u64, 协议本身能装更大,
    /// 但跟 QGA / 主流虚拟机文件粘贴期望一致, 超过引导用户走共享目录.
    public static let maxFileSizeBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// 等 guest 回 CAN_SEND_DATA 的上限. 30s 通常足够; 超过说明 guest 内 spice-vdagent
    /// 没装 / 没响应.
    public static let canSendTimeoutSec: Int = 30

    /// 等终态 (SUCCESS / 错误) 的上限. 大文件按 50 MiB/s 估算: 4 GiB ~ 80s; 600s 留余量.
    public static let finalStatusTimeoutSec: Int = 600

    public struct PasteResult: Sendable {
        public let successful: [String]   // 成功传完的 host 文件路径
        public let skipped: [Skip]        // 主动跳过 (文件夹 / 太大 / 不存在)
        public let failed: [Fail]         // 实际尝试但失败 (vdagent 报错 / 超时)
        public init(successful: [String], skipped: [Skip], failed: [Fail]) {
            self.successful = successful
            self.skipped = skipped
            self.failed = failed
        }
    }
    public struct Skip: Sendable {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) { self.path = path; self.reason = reason }
    }
    public struct Fail: Sendable {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) { self.path = path; self.reason = reason }
    }

    private let vdagent: VdagentClient
    private let stateLock = NSLock()
    /// 每个 transfer id 一个 slot. vdagent callback 写, waitNextStatus 读.
    private var slots: [UInt32: TransferSlot] = [:]

    /// 单 transfer 的 STATUS 邮箱. 用 DispatchSemaphore 计数: 收到一个 status → signal();
    /// 等的人 wait(timeout:) 醒来 → pop 一个 status. 多 status 可堆积 (理论 CAN_SEND_DATA
    /// → SUCCESS 是两次).
    private final class TransferSlot {
        var queue: [VdagentClient.FileXferResult] = []
        let sem = DispatchSemaphore(value: 0)
    }

    public init(vdagent: VdagentClient) {
        self.vdagent = vdagent
    }

    /// 注册 vdagent.onFileXferStatus callback. 必须在 vdagent connect 后 / 任何 sendFileXferStart
    /// 之前调一次. 老 callback 被覆盖 (跟 PasteboardBridge 的 onClipboardTextReceived 不同 slot,
    /// 无冲突).
    public func install() {
        vdagent.onFileXferStatus = { [weak self] id, result in
            self?.recordStatus(id: id, result: result)
        }
        log.info("FilePasteBridge installed onFileXferStatus")
    }

    public func uninstall() {
        vdagent.onFileXferStatus = nil
    }

    // MARK: - slot 管理

    /// vdagent 内部 queue 上调; 入 status 队列 + signal 信号量. 没人等也没事, 下次 wait 立即取走.
    private func recordStatus(id: UInt32, result: VdagentClient.FileXferResult) {
        stateLock.lock()
        let slot = slots[id] ?? TransferSlot()
        slot.queue.append(result)
        slots[id] = slot
        stateLock.unlock()
        // signal 必须在 unlock 后, 否则 sem.wait 醒来抢 stateLock 跟自己死锁? 不会, sem 是
        // 跨 lock 安全的, 但分开调用语义更清晰
        slot.sem.signal()
    }

    /// 同步等下一条 STATUS. timeoutSec 上限后返 nil. 必须在非 main 线程调 (DispatchSemaphore.wait
    /// 会阻塞当前线程).
    private func waitNextStatus(id: UInt32, timeoutSec: Int) -> VdagentClient.FileXferResult? {
        // 1. 取 / 创建 slot, 先看看有没有 buffered status (跟之前 record 抢到序)
        stateLock.lock()
        let slot = slots[id] ?? TransferSlot()
        slots[id] = slot
        if !slot.queue.isEmpty {
            let r = slot.queue.removeFirst()
            stateLock.unlock()
            // 还要 drain 一次 sem (我们没 wait 但 record 已 signal)
            _ = slot.sem.wait(timeout: .now())
            return r
        }
        stateLock.unlock()

        // 2. 阻塞等 sem 或超时. wait(timeout:) 是 kernel timer, 跟 Swift Concurrency 调度无关
        let waitResult = slot.sem.wait(timeout: .now() + .seconds(timeoutSec))
        if waitResult == .timedOut {
            return nil
        }

        // 3. signal 到了, 锁 + pop
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let s = slots[id], !s.queue.isEmpty else {
            // 罕见 race (slot 被另一路径清掉); 当 timeout 处理
            return nil
        }
        return s.queue.removeFirst()
    }

    private func cleanupSlot(id: UInt32) {
        stateLock.lock()
        slots.removeValue(forKey: id)
        stateLock.unlock()
    }

    // MARK: - 公共入口 (async wrapper)

    /// 串行处理 urls. 每个 url 独立 transfer, 之间不并发 (vdagent 单 socket + 协议不可 interleave).
    /// 内部走 Task.detached 跑同步 pipeline, 不阻 main actor.
    public func handlePasteFiles(_ urls: [URL]) async -> PasteResult {
        return await Task.detached(priority: .userInitiated) { [self] in
            self.handlePasteFilesSync(urls)
        }.value
    }

    // MARK: - 同步 pipeline (跑在 Task.detached 内, 用 DispatchSemaphore 等)

    private func handlePasteFilesSync(_ urls: [URL]) -> PasteResult {
        var success: [String] = []
        var skip: [Skip] = []
        var fail: [Fail] = []

        fputs("HVMHost(qemu): FilePasteBridge.handlePasteFilesSync entered urls=\(urls.count)\n", stderr)

        if vdagent.isFileXferDisabledByGuest {
            log.warning("FilePasteBridge: guest 端 FILE_XFER 已禁用 (cap bit 8 置位)")
            return PasteResult(
                successful: [], skipped: [],
                failed: urls.map { Fail(path: $0.path, reason: "guest 端 FILE_XFER 已禁用") }
            )
        }

        for url in urls {
            let path = url.path
            // 1. 文件存在性 + 类型判定
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                skip.append(Skip(path: path, reason: "文件不存在"))
                continue
            }
            if isDir.boolValue {
                skip.append(Skip(path: path, reason: "暂不支持文件夹, 请先压缩"))
                continue
            }
            // 2. 大小检查
            let size: UInt64
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                guard let n = attrs[.size] as? NSNumber else {
                    skip.append(Skip(path: path, reason: "读取文件大小失败"))
                    continue
                }
                size = n.uint64Value
            } catch {
                skip.append(Skip(path: path, reason: "stat 失败: \(error)"))
                continue
            }
            if size > Self.maxFileSizeBytes {
                skip.append(Skip(path: path, reason: "文件超过 4 GiB 上限, 请走共享目录"))
                continue
            }
            // 3. 实际传输 (同步, 走 DispatchSemaphore)
            switch streamOneSync(url: url, size: size) {
            case .ok:
                success.append(path)
            case .failed(let reason):
                fail.append(Fail(path: path, reason: reason))
            }
        }
        return PasteResult(successful: success, skipped: skip, failed: fail)
    }

    private enum OneResult { case ok; case failed(String) }

    private func streamOneSync(url: URL, size: UInt64) -> OneResult {
        let basename = url.lastPathComponent
        fputs("HVMHost(qemu): streamOneSync name=\(basename) size=\(size)\n", stderr)

        let id = vdagent.sendFileXferStart(name: basename, size: size)
        fputs("HVMHost(qemu): sendFileXferStart→ id=\(id), 等 CAN_SEND_DATA\n", stderr)

        // 等 CAN_SEND_DATA (或终态错误)
        guard let s1 = waitNextStatus(id: id, timeoutSec: Self.canSendTimeoutSec) else {
            cleanupSlot(id: id)
            fputs("HVMHost(qemu): CAN_SEND_DATA TIMEOUT id=\(id)\n", stderr)
            return .failed("等 CAN_SEND_DATA 超时 (\(Self.canSendTimeoutSec)s); guest 端 spice-vdagent 可能未安装或未启")
        }
        fputs("HVMHost(qemu): 收到 status id=\(id) raw=\(s1.rawValue)\n", stderr)
        guard s1 == .canSendData else {
            cleanupSlot(id: id)
            return .failed("guest 拒绝传输: \(describe(s1))")
        }

        // 流 chunks. 单 chunk payload = fileXferChunkSize (2000 B).
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            vdagent.sendFileXferStatus(id: id, result: .cancelled)
            cleanupSlot(id: id)
            return .failed("打开 host 文件失败: \(error)")
        }
        defer { try? fh.close() }

        var sent: UInt64 = 0
        do {
            while true {
                guard let chunk = try fh.read(upToCount: VdagentClient.fileXferChunkSize) else {
                    break
                }
                if chunk.isEmpty { break }
                vdagent.sendFileXferData(id: id, chunk: chunk)
                sent &+= UInt64(chunk.count)
            }
        } catch {
            vdagent.sendFileXferStatus(id: id, result: .error)
            cleanupSlot(id: id)
            return .failed("读取 host 文件失败: \(error)")
        }
        fputs("HVMHost(qemu): 数据流完, 等终态 id=\(id) sent=\(sent)\n", stderr)

        // 等终态
        guard let s2 = waitNextStatus(id: id, timeoutSec: Self.finalStatusTimeoutSec) else {
            cleanupSlot(id: id)
            fputs("HVMHost(qemu): final status TIMEOUT id=\(id)\n", stderr)
            return .failed("等 SUCCESS 超时 (\(Self.finalStatusTimeoutSec)s); guest 端可能挂了")
        }
        cleanupSlot(id: id)
        fputs("HVMHost(qemu): 终态 id=\(id) raw=\(s2.rawValue)\n", stderr)
        if s2 == .success {
            log.info("FilePasteBridge done id=\(id, privacy: .public) name=\(basename, privacy: .public) size=\(size, privacy: .public)")
            return .ok
        }
        return .failed("guest 处理失败: \(describe(s2))")
    }

    private func describe(_ r: VdagentClient.FileXferResult) -> String {
        switch r {
        case .canSendData:        return "can_send_data (异常状态; 终态期望 SUCCESS)"
        case .cancelled:          return "已取消"
        case .error:              return "通用错误"
        case .success:            return "成功"
        case .notEnoughSpace:     return "guest 磁盘空间不足"
        case .sessionLocked:      return "guest 会话已锁屏"
        case .vdagentNotConnected: return "guest 内 vdagent 未连接"
        case .disabled:           return "guest 已禁用文件传输"
        }
    }
}
