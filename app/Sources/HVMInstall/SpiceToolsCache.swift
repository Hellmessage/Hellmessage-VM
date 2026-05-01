// HVMInstall/SpiceToolsCache.swift
// spice-guest-tools.exe 全局缓存 + 按需下载.
//
// 用途: Windows guest 内安装 spice-vdagent 服务后, 能响应 host 通过 vdagent
// virtio-serial 通道发的 monitor config (HDP RESIZE_REQUEST → QEMU dpy_set_ui_info →
// vdagent), 实现拖 HVM 主窗口动态切 guest 分辨率. 不装的话 host 拖窗口 guest
// 不改分辨率 (frame buffer 拉伸 / 黑边).
//
// 缓存策略 (跟 VirtioWinCache 同模式):
//   - 全局共享: ~/Library/Application Support/HVM/cache/spice-tools/spice-guest-tools.exe
//     所有 Win VM 引用同一份 (~30MB 一次, 不每个 VM 复制)
//   - 创建 Win VM 时按需下载 (前台 modal 进度); 已存在 + 文件大小合理 → 直接复用
//   - WindowsUnattend.ensureISO 把这个 .exe 拷进 unattend ISO stage,
//     OOBE FirstLogonCommands 静默 NSIS /S 安装. ARM64 Windows 通过 x86 emulation
//     跑 x86 NSIS installer, spice-space 社区已验证 OK.
//
// 失败策略: 下载失败允许跳过, VM 仍能启动, 只是 Windows guest 拖窗口不自动
// resize (Linux guest 不受影响, kernel 自带 virtio-gpu 驱动响应 EDID 变化).
//
// 下载源: spice-space.org 官方 latest 直链.
//   https://www.spice-space.org/download/binaries/spice-guest-tools/spice-guest-tools-latest.exe
// 环境变量 HVM_SPICE_TOOLS_URL 可覆盖 (内部镜像 / 离线分发).

import Foundation
import HVMCore

public enum SpiceToolsCache {

    /// 上游 latest 直链. HVM_SPICE_TOOLS_URL env 覆盖 (内部镜像).
    public static var downloadURL: URL {
        if let env = ProcessInfo.processInfo.environment["HVM_SPICE_TOOLS_URL"],
           let u = URL(string: env) {
            return u
        }
        return URL(string:
            "https://www.spice-space.org/download/binaries/spice-guest-tools/spice-guest-tools-latest.exe"
        )!
    }

    /// 缓存文件绝对路径
    public static var cachedExeURL: URL {
        HVMPaths.spiceToolsCacheDir.appendingPathComponent("spice-guest-tools.exe")
    }

    /// 缓存就绪判定 (存在 + 大小 ≥ 5MB sanity; 上游 .exe 实际 ~30MB)
    public static var isReady: Bool {
        let path = cachedExeURL.path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size >= 5 * 1024 * 1024
        else { return false }
        return true
    }

    /// 已缓存文件大小 (bytes); 不存在返 nil
    public static var cachedSizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cachedExeURL.path),
              let n = attrs[.size] as? Int64 else { return nil }
        return n
    }

    /// 下载进度 (跟 VirtioWinCache.Progress 同形)
    public struct Progress: Sendable, Equatable {
        public let receivedBytes: Int64
        /// 服务端 Content-Length (有时 nil)
        public let totalBytes: Int64?

        public init(receivedBytes: Int64, totalBytes: Int64?) {
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
        }

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

    /// 确保缓存就绪. 已就绪直接返回; 否则前台下载并报告进度.
    /// progress 在任意线程调用; UI 调用方需自行 dispatch 主线程.
    public static func ensureCached(
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        if isReady {
            return cachedExeURL
        }
        try HVMPaths.ensure(HVMPaths.spiceToolsCacheDir)

        let partialURL = cachedExeURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        try await streamDownload(from: downloadURL, to: partialURL, progress: progress)

        try? FileManager.default.removeItem(at: cachedExeURL)
        try FileManager.default.moveItem(at: partialURL, to: cachedExeURL)

        guard isReady else {
            throw DownloadError.downloadFailed(
                reason: "下载完成但文件大小异常 (\(cachedSizeBytes ?? 0) bytes)"
            )
        }
        return cachedExeURL
    }

    /// 删除已缓存文件 (UI 提供"重新下载"或排错时用)
    public static func purge() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedExeURL.path) {
            try fm.removeItem(at: cachedExeURL)
        }
        let partial = cachedExeURL.appendingPathExtension("partial")
        if fm.fileExists(atPath: partial.path) {
            try fm.removeItem(at: partial)
        }
    }

    // MARK: - 内部: URLSessionDownloadTask 包装 (跟 VirtioWinCache 同实现)

    private static func streamDownload(
        from url: URL,
        to dest: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = SpiceDownloadDelegate(destination: dest, progress: progress, continuation: cont)
            let session = URLSession(configuration: .default,
                                     delegate: delegate,
                                     delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }
}

/// URLSessionDownloadDelegate (一次性). 跟 VirtioWinCache 内 DownloadDelegate 同形.
private final class SpiceDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progressCb: @Sendable (SpiceToolsCache.Progress) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    private let lock = NSLock()
    private var resolved = false

    init(destination: URL,
         progress: @escaping @Sendable (SpiceToolsCache.Progress) -> Void,
         continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.progressCb = progress
        self.continuation = continuation
    }

    private func resolve(with result: Result<Void, Error>) {
        lock.lock()
        if resolved { lock.unlock(); return }
        resolved = true
        let cont = continuation; continuation = nil
        let s = session; session = nil
        lock.unlock()

        s?.invalidateAndCancel()
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            resolve(with: .failure(SpiceToolsCache.DownloadError.httpStatus(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            resolve(with: .success(()))
        } catch {
            resolve(with: .failure(SpiceToolsCache.DownloadError.writeFailed(reason: "\(error)")))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressCb(SpiceToolsCache.Progress(
            receivedBytes: totalBytesWritten,
            totalBytes: total
        ))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            resolve(with: .failure(error))
        }
    }
}
