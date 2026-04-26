// HVMInstall/VirtioWinCache.swift
// virtio-win.iso 全局缓存 + 按需下载. Win11 arm64 装机必需 (没驱动 installer 看不到 virtio-blk 磁盘).
//
// 缓存策略 (用户决策 D2):
//   - 全局共享: ~/Library/Application Support/HVM/cache/virtio-win/virtio-win.iso
//     所有 Win VM 引用同一份 (700MB 一次, 不每个 VM 复制)
//   - 创建 Win VM 时按需下载 (前台 modal 进度); 已存在 + 文件大小合理 → 直接复用
//   - 不做断点续传一期 (实现复杂度对 700MB 单次下载性价比低; 失败重新下)
//
// 下载源: Fedora 官方 (libvirt 上游, 稳定 channel)
//   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso

import Foundation
import HVMCore

public enum VirtioWinCache {

    /// 上游稳定版固定 URL (latest -> redirect 到具体版本; 我们直接拿稳定 alias)
    public static let downloadURL = URL(string:
        "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    )!

    /// 缓存文件绝对路径
    public static var cachedISOURL: URL {
        HVMPaths.virtioWinCacheDir.appendingPathComponent("virtio-win.iso")
    }

    /// 缓存就绪判定 (存在 + 大小 ≥ 100MB sanity; 上游 ISO 实际 ~700MB)
    public static var isReady: Bool {
        let path = cachedISOURL.path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size >= 100 * 1024 * 1024
        else { return false }
        return true
    }

    /// 已缓存文件大小 (bytes); 不存在返 nil
    public static var cachedSizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cachedISOURL.path),
              let n = attrs[.size] as? Int64 else { return nil }
        return n
    }

    /// 下载进度
    public struct Progress: Sendable, Equatable {
        public let receivedBytes: Int64
        /// 服务端 Content-Length (有时 nil; 无法显示百分比时 UI 退化为字节数)
        public let totalBytes: Int64?

        public init(receivedBytes: Int64, totalBytes: Int64?) {
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
        }

        /// 0.0...1.0; totalBytes 缺失时返 nil
        public var fraction: Double? {
            guard let t = totalBytes, t > 0 else { return nil }
            return Double(receivedBytes) / Double(t)
        }
    }

    public enum DownloadError: Error, Sendable, Equatable {
        case httpStatus(Int)
        case writeFailed(reason: String)
        case downloadFailed(reason: String)
        case cancelled
    }

    /// 确保缓存就绪. 已就绪直接返回; 否则前台下载并报告进度. 抛 CancellationError 可取消.
    /// progress 在任意线程调用; UI 调用方需自行 dispatch 主线程.
    public static func ensureCached(
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        if isReady {
            return cachedISOURL
        }
        try HVMPaths.ensure(HVMPaths.virtioWinCacheDir)

        // 先下到 .partial, 完成后原子 rename (中途崩 / 取消不污染 cache)
        let partialURL = cachedISOURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        try await streamDownload(from: downloadURL, to: partialURL, progress: progress)

        // 落定
        try? FileManager.default.removeItem(at: cachedISOURL)
        try FileManager.default.moveItem(at: partialURL, to: cachedISOURL)

        // 落定后再 sanity check
        guard isReady else {
            throw DownloadError.downloadFailed(
                reason: "下载完成但文件大小异常 (\(cachedSizeBytes ?? 0) bytes)"
            )
        }
        return cachedISOURL
    }

    /// 删除已缓存文件 (UI 提供"重新下载"或排错时用)
    public static func purge() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedISOURL.path) {
            try fm.removeItem(at: cachedISOURL)
        }
        let partial = cachedISOURL.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try fm.removeItem(at: partial)
        }
    }

    // MARK: - 内部: URLSessionDownloadTask 包装

    private static func streamDownload(
        from url: URL,
        to dest: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(destination: dest, progress: progress, continuation: cont)
            // 用 default config; 后台/wifi-only 等约束未来再加
            let session = URLSession(configuration: .default,
                                     delegate: delegate,
                                     delegateQueue: nil)
            // 持有 delegate 直到回调完成 (delegate 回调里 invalidate session 释放)
            delegate.session = session
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }
}

/// URLSessionDownloadDelegate: 流式下载 + 进度桥接到 Continuation.
/// 一次性使用; 完成 / 失败后立即 invalidate session.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progressCb: @Sendable (VirtioWinCache.Progress) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    private let lock = NSLock()
    private var resolved = false

    init(destination: URL,
         progress: @escaping @Sendable (VirtioWinCache.Progress) -> Void,
         continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.progressCb = progress
        self.continuation = continuation
    }

    private func resolve(with result: Result<Void, Error>) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        let cont = continuation
        continuation = nil
        let s = session
        session = nil
        lock.unlock()

        s?.invalidateAndCancel()
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 检查 HTTP 状态
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            resolve(with: .failure(VirtioWinCache.DownloadError.httpStatus(http.statusCode)))
            return
        }
        // 移到目标 (location 是 URLSession 临时目录, 进程退出会清; 必须立即 move)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            resolve(with: .success(()))
        } catch {
            resolve(with: .failure(VirtioWinCache.DownloadError.writeFailed(reason: "\(error)")))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressCb(VirtioWinCache.Progress(
            receivedBytes: totalBytesWritten,
            totalBytes: total
        ))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            // didFinishDownloadingTo 走过的成功路径不会到这 (已 resolved); 真错误才 fail.
            // CancellationError 也算错误传递出去
            resolve(with: .failure(error))
        }
    }
}
