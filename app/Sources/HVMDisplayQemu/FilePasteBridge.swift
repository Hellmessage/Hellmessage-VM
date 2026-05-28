// HVMDisplayQemu/FilePasteBridge.swift
//
// host → guest 文件粘贴桥. 详见 docs/v3/HOST_FILE_PASTE.md.
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
// 边界:
//   - 文件夹: skip + 通知 "暂不支持"
//   - 单文件 > 4 GiB: skip (跟 SPICE 协议 + QGA 一致)
//   - guest 未装 spice-vdagent: 等 CAN_SEND_DATA 30s 超时 → 报错
//   - 串行不并发: vdagent socket 单 client + SPICE 协议 chunks 不可 interleave

import Foundation
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "FilePaste")

/// 非 actor; 内部用 NSLock 保护 mailbox state. 调用方走 await, 实际工作在 cooperative
/// executor 非 main 线程. 跟 VdagentClient 一样 @unchecked Sendable 兜底.
public final class FilePasteBridge: @unchecked Sendable {

    /// 单文件 4 GiB 软上限. SPICE FILE_XFER_DATA size 字段是 u64, 协议本身能装更大,
    /// 但跟 QGA / 主流虚拟机文件粘贴期望一致, 超过引导用户走共享目录.
    public static let maxFileSizeBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// 等 guest 回 CAN_SEND_DATA 的上限. 30s 通常足够; 超过说明 guest 内 spice-vdagent
    /// 没装 / 没响应.
    public static let canSendTimeoutSec: Double = 30

    /// 等终态 (SUCCESS / 错误) 的上限. 大文件按 50 MiB/s 估算: 4 GiB ~ 80s; 600s 留余量.
    public static let finalStatusTimeoutSec: Double = 600

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
    /// 每个 transfer id 一个 mailbox 收 STATUS. vdagent callback 写, awaitStatus 读.
    private var mailboxes: [UInt32: Mailbox] = [:]

    private struct Mailbox {
        var queue: [VdagentClient.FileXferResult] = []
        var continuation: CheckedContinuation<VdagentClient.FileXferResult, Never>?
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

    // MARK: - mailbox

    /// vdagent 内部 queue 上调; 写 mailbox 或唤醒已挂着的 continuation.
    private func recordStatus(id: UInt32, result: VdagentClient.FileXferResult) {
        stateLock.lock()
        var mb = mailboxes[id] ?? Mailbox()
        if let cont = mb.continuation {
            mb.continuation = nil
            mailboxes[id] = mb
            stateLock.unlock()
            cont.resume(returning: result)
        } else {
            mb.queue.append(result)
            mailboxes[id] = mb
            stateLock.unlock()
        }
    }

    /// 等下一条 STATUS. 已有 buffered 直接返; 没有就挂 continuation.
    private func nextStatus(id: UInt32) async -> VdagentClient.FileXferResult {
        return await withCheckedContinuation {
            (cont: CheckedContinuation<VdagentClient.FileXferResult, Never>) in
            stateLock.lock()
            var mb = mailboxes[id] ?? Mailbox()
            if !mb.queue.isEmpty {
                let r = mb.queue.removeFirst()
                mailboxes[id] = mb
                stateLock.unlock()
                cont.resume(returning: r)
            } else {
                mb.continuation = cont
                mailboxes[id] = mb
                stateLock.unlock()
            }
        }
    }

    /// 等 STATUS 或 timeoutSec 秒后超时返 nil. 不取消传输; 调用方决定是否 cleanup.
    private func awaitStatus(id: UInt32, timeoutSec: Double) async -> VdagentClient.FileXferResult? {
        return await withTaskGroup(of: VdagentClient.FileXferResult??.self) { group in
            group.addTask { [weak self] in
                guard let self else { return .some(nil) }
                return .some(await self.nextStatus(id: id))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                return .some(nil)
            }
            let first = await group.next() ?? .some(nil)
            group.cancelAll()
            return first ?? nil
        }
    }

    private func cleanupMailbox(id: UInt32) {
        stateLock.lock()
        mailboxes.removeValue(forKey: id)
        stateLock.unlock()
    }

    // MARK: - 公共入口

    /// 串行处理 urls. 每个 url 独立 transfer, 之间不并发 (vdagent 单 socket + 协议不可 interleave).
    /// 整批最大耗时 = ∑ 单文件传输; 大批量大文件时调用方应自行做超时控制.
    public func handlePasteFiles(_ urls: [URL]) async -> PasteResult {
        var success: [String] = []
        var skip: [Skip] = []
        var fail: [Fail] = []

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
            // 3. 实际传输
            switch await streamOne(url: url, size: size) {
            case .ok:
                success.append(path)
            case .failed(let reason):
                fail.append(Fail(path: path, reason: reason))
            }
        }
        return PasteResult(successful: success, skipped: skip, failed: fail)
    }

    // MARK: - 单文件流式

    private enum OneResult { case ok; case failed(String) }

    private func streamOne(url: URL, size: UInt64) async -> OneResult {
        let basename = url.lastPathComponent
        let id = vdagent.sendFileXferStart(name: basename, size: size)

        // 等 CAN_SEND_DATA (或终态错误)
        guard let s1 = await awaitStatus(id: id, timeoutSec: Self.canSendTimeoutSec) else {
            cleanupMailbox(id: id)
            return .failed("等 CAN_SEND_DATA 超时 (\(Int(Self.canSendTimeoutSec))s); guest 端 spice-vdagent 可能未安装或未启")
        }
        guard s1 == .canSendData else {
            cleanupMailbox(id: id)
            return .failed("guest 拒绝传输: \(describe(s1))")
        }

        // 串 chunks. 单 chunk payload = fileXferChunkSize (2000 B).
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            vdagent.sendFileXferStatus(id: id, result: .cancelled)
            cleanupMailbox(id: id)
            return .failed("打开 host 文件失败: \(error)")
        }
        defer { try? fh.close() }

        var sent: UInt64 = 0
        // 简单 backpressure: 每 N chunks 让出一次 cooperative pool, 防止读快写慢导致
        // vdagent.queue 积压数百 MB Data block. 256 chunks ~ 512 KiB, await 让其它 task
        // (包括 vdagent send queue 的 drain) 跑.
        let yieldEveryChunks = 256
        var sinceYield = 0
        do {
            while true {
                guard let chunk = try fh.read(upToCount: VdagentClient.fileXferChunkSize) else {
                    break
                }
                if chunk.isEmpty { break }
                vdagent.sendFileXferData(id: id, chunk: chunk)
                sent &+= UInt64(chunk.count)
                sinceYield += 1
                if sinceYield >= yieldEveryChunks {
                    sinceYield = 0
                    await Task.yield()
                }
            }
        } catch {
            vdagent.sendFileXferStatus(id: id, result: .error)
            cleanupMailbox(id: id)
            return .failed("读取 host 文件失败: \(error)")
        }

        // 等终态
        guard let s2 = await awaitStatus(id: id, timeoutSec: Self.finalStatusTimeoutSec) else {
            cleanupMailbox(id: id)
            return .failed("等 SUCCESS 超时 (\(Int(Self.finalStatusTimeoutSec))s); guest 端可能挂了")
        }
        cleanupMailbox(id: id)
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
