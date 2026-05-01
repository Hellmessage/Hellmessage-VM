// HVMInstall/UtmGuestToolsCache.swift
// UTM Guest Tools ISO 全局缓存 + 按需下载.
//
// 老 cache (`cache/spice-tools/spice-guest-tools.exe` 或 `cache/spice-tools/utm-guest-tools.iso`)
// 不会自动迁移; 用户旧版本下过的产物会成为 orphan, 自行清理或随其他维护操作删除.
//
// 用途: Windows ARM64 guest 内安装 utmapp 自家 SPICE 客户端套件 (含 ARM64 native
// spice-vdagent.exe + utmapp/virtio-gpu-wddm-dod 自家 viogpudo.sys), 才能让 host 通过
// SPICE main channel 发的 VDAgentMonitorsConfig 真改 guest 分辨率, 实现拖窗口 dynamic
// resize.
//
// **不再用** stock spice-guest-tools.exe (spice-space.org 上游): 它只有 x86 binary,
// ARM Win 跑 x86 emu vdagent 调 D3DKMTEscape 路径走不通; 而且它装的 stock viogpudo
// 没实现 QXL escape SET_CUSTOM_DISPLAY 等关键路径. 切到 UTM Guest Tools 后, ARM64
// native vdagent + utmapp viogpudo 完整跑通 dynamic resize 链路.
//
// 缓存策略 (跟 VirtioWinCache 同模式):
//   - 全局共享: ~/Library/Application Support/HVM/cache/utm-guest-tools/utm-guest-tools.iso
//     所有 Win VM 引用同一份 (~120MB 一次, 不每个 VM 复制)
//   - 创建 Win VM 时按需下载 (前台 modal 进度); 已存在 + 文件大小合理 → 直接复用
//   - QemuArgsBuilder 把 ISO 当第三 cdrom 挂给 Win guest, OOBE FirstLogonCommands
//     扫所有盘符找 utm-guest-tools-*.exe 跑 NSIS /S 静默安装
//
// 失败策略: 下载失败允许跳过, VM 仍能启动, 只是 Windows guest 拖窗口不 resize
// (Linux guest 不受影响, kernel 自带 virtio-gpu 驱动响应 EDID 变化).
//
// 下载源: getutm.app 官方 latest 直链 (重定向到 utmapp/qemu releases).
//   https://getutm.app/downloads/utm-guest-tools-latest.iso
// 环境变量 HVM_UTM_GUEST_TOOLS_URL 可覆盖 (内部镜像 / 离线分发).

import Foundation
import HVMCore

public enum UtmGuestToolsCache {

    /// 上游 latest 直链. HVM_UTM_GUEST_TOOLS_URL env 覆盖 (内部镜像).
    public static var downloadURL: URL {
        if let env = ProcessInfo.processInfo.environment["HVM_UTM_GUEST_TOOLS_URL"],
           let u = URL(string: env) {
            return u
        }
        return URL(string:
            "https://getutm.app/downloads/utm-guest-tools-latest.iso"
        )!
    }

    /// 缓存文件绝对路径. 文件名固定 utm-guest-tools.iso (上游 release 是 utm-guest-tools-X.Y.ZZZ.iso,
    /// 我们 normalize 成无版本号文件名, 升级时直接覆盖)
    public static var cachedISOURL: URL {
        HVMPaths.utmGuestToolsCacheDir.appendingPathComponent("utm-guest-tools.iso")
    }

    /// 缓存就绪判定 (存在 + 大小 ≥ 50MB sanity; 上游 ISO 实际 ~120MB).
    /// 第一次调用时触发一次 legacy mv (老 cache `cache/spice-tools/utm-guest-tools.iso`
    /// → 新路径), 后续 access 不再做 IO 副作用.
    public static var isReady: Bool {
        _ = _legacyMigrateOnce
        let path = cachedISOURL.path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size >= 50 * 1024 * 1024
        else { return false }
        return true
    }

    /// 一次性 lazy 迁移 SpiceToolsCache 时代的老 cache 路径
    /// (~/Library/Application Support/HVM/cache/spice-tools/utm-guest-tools.iso) 到新
    /// 路径. static let 闭包保证整个进程只跑一次; 失败 (跨卷 / 权限 / 已被改) 不抛出,
    /// 下次进程启动再试 — legacy 文件留在原地不丢.
    private static let _legacyMigrateOnce: Void = {
        let fm = FileManager.default
        let legacyURL = HVMPaths.appSupport
            .appendingPathComponent("cache/spice-tools/utm-guest-tools.iso")
        let newURL = HVMPaths.utmGuestToolsCacheDir
            .appendingPathComponent("utm-guest-tools.iso")
        guard fm.fileExists(atPath: legacyURL.path),
              !fm.fileExists(atPath: newURL.path) else { return }
        do {
            try HVMPaths.ensure(HVMPaths.utmGuestToolsCacheDir)
            try fm.moveItem(at: legacyURL, to: newURL)
        } catch {
            // legacy 仍在原处, 下次进程再试; user 也可手动 mv.
        }
    }()

    /// 已缓存文件大小 (bytes); 不存在返 nil
    public static var cachedSizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cachedISOURL.path),
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
        _ = _legacyMigrateOnce
        if isReady {
            return cachedISOURL
        }
        try HVMPaths.ensure(HVMPaths.utmGuestToolsCacheDir)

        let partialURL = cachedISOURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        try await streamDownload(from: downloadURL, to: partialURL, progress: progress)

        try? FileManager.default.removeItem(at: cachedISOURL)
        try FileManager.default.moveItem(at: partialURL, to: cachedISOURL)

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

    // MARK: - 内部: URLSessionDownloadTask 包装 (跟 VirtioWinCache 同实现)

    private static func streamDownload(
        from url: URL,
        to dest: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = UtmGuestToolsDownloadDelegate(destination: dest, progress: progress, continuation: cont)
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
private final class UtmGuestToolsDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progressCb: @Sendable (UtmGuestToolsCache.Progress) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    private let lock = NSLock()
    private var resolved = false

    init(destination: URL,
         progress: @escaping @Sendable (UtmGuestToolsCache.Progress) -> Void,
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
            resolve(with: .failure(UtmGuestToolsCache.DownloadError.httpStatus(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            resolve(with: .success(()))
        } catch {
            resolve(with: .failure(UtmGuestToolsCache.DownloadError.writeFailed(reason: "\(error)")))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressCb(UtmGuestToolsCache.Progress(
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
