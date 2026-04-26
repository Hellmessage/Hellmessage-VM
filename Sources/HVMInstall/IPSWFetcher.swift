// HVMInstall/IPSWFetcher.swift
// IPSW 下载器. 走 VZMacOSRestoreImage.fetchLatestSupported 拿最新远程 URL,
// 自己用 URLSessionDataTask + HTTP Range 头流式落到
// ~/Library/Application Support/HVM/cache/ipsw/<build>.ipsw, 进度按 100ms 节流上报.
//
// 决策 J1: 不走 Apple SUCatalog (XML 解析、需手动算 hash), VZ 直接给我们 IPSW URL,
// 配合 RestoreImageHandle 后续校验 mostFeaturefulSupportedConfiguration 已足够.
//
// === 断点续传 ===
//
// 不用 URLSessionDownloadTask + resumeData (跨进程不可靠 / tmp 路径不可控). 自己管文件:
//   1. 下载中文件名 <build>.ipsw.partial; 完成后原子 rename -> <build>.ipsw
//   2. 首次响应时把服务器的 ETag / Last-Modified 写到 sidecar <build>.ipsw.partial.meta
//   3. 下次 fetch 检查 .partial size > 0 → 发 Range: bytes=N- + If-Range: <validator>
//   4. 服务器响应:
//      - 206 Partial Content → seek-to-end 后 append (validator 仍匹配)
//      - 200 OK              → 服务器忽略 Range 或 If-Range 不匹配 (文件变了),
//                              truncate .partial 从头开始, 同时刷新 .meta
//      - 416 Range Not Satisfiable → 校验 Content-Range: */<total> 中的 total
//                                    与本地 .partial size 一致才 promote;
//                                    不一致 → truncate + auto-retry 一次 (resumeFrom=0)
//   5. App 崩溃 / 系统重启 / kill -9 都不影响, .partial + .meta 留在 cache 目录,
//      下次 fetch 自动续传, validator 不匹配会安全 fallback 到全新下载
//
// Apple CDN 静态 IPSW 资源原生支持 Range + If-Range, 上述路径稳定.
//
// 缓存约束:
//   - 文件名固定 <buildVersion>.ipsw, build 一致即认为同一份
//   - 已存在 + 大小 > 0 视为可用; 上层 (RestoreImageHandle.load) 会做内容校验
//   - --force 同时清 .ipsw + .partial + .meta
//   - rm <build> 也同时清三者
//
// 详见 docs/GUEST_OS_INSTALL.md "IPSW 缓存管理".

import Foundation
@preconcurrency import Virtualization
import HVMCore

// MARK: - 公开类型

/// 远程 IPSW 元信息 (从 VZMacOSRestoreImage 抽 sendable 字段)
public struct IPSWCatalogEntry: Sendable, Equatable, Codable {
    /// 例 "24A335"
    public let buildVersion: String
    /// 例 "15.0.1"
    public let osVersion: String
    /// VZ 给的远程下载 URL (https://updates.cdn-apple.com/...)
    public let url: URL
    /// IPSW 推荐的最低 CPU 数 (来自 mostFeaturefulSupportedConfiguration)
    public let minCPU: Int
    /// IPSW 推荐的最低内存 (MiB)
    public let minMemoryMiB: UInt64

    public init(buildVersion: String, osVersion: String, url: URL, minCPU: Int, minMemoryMiB: UInt64) {
        self.buildVersion = buildVersion
        self.osVersion = osVersion
        self.url = url
        self.minCPU = minCPU
        self.minMemoryMiB = minMemoryMiB
    }
}

/// 下载进度阶段
public enum IPSWFetchPhase: String, Sendable, Equatable, Codable {
    case resolving       // 调 VZMacOSRestoreImage.fetchLatestSupported
    case downloading     // URLSession 拉数据
    case completed       // 已落到 cache
    case alreadyCached   // 缓存已命中, 跳过下载
}

public struct IPSWFetchProgress: Sendable, Equatable {
    public let phase: IPSWFetchPhase
    /// 已收字节; resolving / alreadyCached 阶段为 0
    public let receivedBytes: Int64
    /// 期望总字节; nil 表示服务器没给 Content-Length
    public let totalBytes: Int64?

    public init(phase: IPSWFetchPhase, receivedBytes: Int64 = 0, totalBytes: Int64? = nil) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

/// 已缓存的 IPSW 条目 (本地文件)
public struct IPSWCacheItem: Sendable, Equatable, Codable {
    public let buildVersion: String
    public let path: String
    public let sizeBytes: Int64

    public init(buildVersion: String, path: String, sizeBytes: Int64) {
        self.buildVersion = buildVersion
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

// MARK: - 主实现

public enum IPSWFetcher {
    private static let log = HVMLog.logger("install.ipsw")

    /// 查询 Apple 当前推荐的最新 macOS guest IPSW. 不下载, 仅返回元信息.
    /// 失败抛 .install(.ipswDownloadFailed)
    public static func resolveLatest() async throws -> IPSWCatalogEntry {
        Self.log.info("resolveLatest: VZMacOSRestoreImage.fetchLatestSupported")
        // VZMacOSRestoreImage 不是 Sendable, 跨 continuation 包一层 box.
        struct ImageBox: @unchecked Sendable { let value: VZMacOSRestoreImage }

        let box: ImageBox
        do {
            box = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ImageBox, Error>) in
                VZMacOSRestoreImage.fetchLatestSupported { result in
                    switch result {
                    case .success(let img): cont.resume(returning: ImageBox(value: img))
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }
            }
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "fetchLatestSupported: \(error)"))
        }

        let image = box.value
        guard let req = image.mostFeaturefulSupportedConfiguration else {
            throw HVMError.install(.ipswUnsupported(
                reason: "VZ 报告该 IPSW 无受支持配置 (mostFeaturefulSupportedConfiguration=nil); 可能本机硬件太老"
            ))
        }
        let v = image.operatingSystemVersion
        let osVer = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let entry = IPSWCatalogEntry(
            buildVersion: image.buildVersion,
            osVersion: osVer,
            url: image.url,
            minCPU: req.minimumSupportedCPUCount,
            minMemoryMiB: req.minimumSupportedMemorySize / (1024 * 1024)
        )
        Self.log.info("resolveLatest: build=\(entry.buildVersion, privacy: .public) os=\(entry.osVersion, privacy: .public)")
        return entry
    }

    /// 给定 entry 计算其在 cache 内应有的本地路径 (不保证存在).
    public static func cachedPath(for entry: IPSWCatalogEntry) -> URL {
        cachedPath(buildVersion: entry.buildVersion)
    }

    public static func cachedPath(buildVersion: String) -> URL {
        HVMPaths.ipswCacheDir.appendingPathComponent("\(buildVersion).ipsw")
    }

    /// 半成品路径 (下载中). 完成后 atomic rename 到 cachedPath.
    public static func partialPath(buildVersion: String) -> URL {
        cachedPath(buildVersion: buildVersion).appendingPathExtension("partial")
    }

    /// 半成品 sidecar meta 路径 (含 ETag / Last-Modified, 用于 If-Range 校验).
    /// 与 .partial 成对存在; promote / 删除 / truncate 都会同步收尾.
    public static func partialMetaPath(buildVersion: String) -> URL {
        partialPath(buildVersion: buildVersion).appendingPathExtension("meta")
    }

    /// 缓存命中检查. 文件存在且大小 > 0 即认为可用 (上层 RestoreImageHandle.load 会做内容校验).
    public static func isCached(buildVersion: String) -> Bool {
        let p = cachedPath(buildVersion: buildVersion).path
        guard let attr = try? FileManager.default.attributesOfItem(atPath: p),
              let size = attr[.size] as? Int64, size > 0 else {
            return false
        }
        return true
    }

    /// 半成品大小 (字节). 不存在或读不到返 0.
    public static func partialSize(buildVersion: String) -> Int64 {
        let p = partialPath(buildVersion: buildVersion).path
        return (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
    }

    /// 列出 cache 目录里的所有 IPSW.
    public static func listCache() -> [IPSWCacheItem] {
        let dir = HVMPaths.ipswCacheDir
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> IPSWCacheItem? in
            guard url.pathExtension.lowercased() == "ipsw" else { return nil }
            let build = url.deletingPathExtension().lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return IPSWCacheItem(buildVersion: build, path: url.path, sizeBytes: size)
        }
        .sorted { $0.buildVersion < $1.buildVersion }
    }

    /// 删除单个缓存 (含 .partial + .meta sidecar). 不存在静默通过 (幂等).
    public static func removeCache(buildVersion: String) throws {
        let paths = [
            cachedPath(buildVersion: buildVersion),
            partialPath(buildVersion: buildVersion),
            partialMetaPath(buildVersion: buildVersion),
        ]
        for p in paths where FileManager.default.fileExists(atPath: p.path) {
            do {
                try FileManager.default.removeItem(at: p)
            } catch {
                throw HVMError.install(.ipswDownloadFailed(reason: "rm cache \(p.lastPathComponent): \(error)"))
            }
        }
    }

    /// 清空整个 cache 目录 (内 IPSW 文件).
    public static func clearAllCache() throws {
        for item in listCache() {
            try removeCache(buildVersion: item.buildVersion)
        }
    }

    /// 下载 entry 指向的 IPSW 到 cache. 自动断点续传 (有 .partial 即续传, 无则全新下).
    /// - 已缓存 (.ipsw 存在 + size>0): 跳过, 推送 .alreadyCached
    /// - force: 同时清 .ipsw + .partial + .meta, 全新下载
    /// - onProgress: 调用上下文 = 后台 URLSession delegate queue, 不要直接动 UI; 调用方应自己调度回主线程
    ///
    /// 内部对 416 (.partial 大小 > 服务器 total) 做一次 auto-retry: truncate 后递归重下,
    /// 防止用户看到难懂的 416 错误. retry 只走一次, 二次失败抛出.
    @discardableResult
    public static func downloadIfNeeded(
        entry: IPSWCatalogEntry,
        force: Bool = false,
        onProgress: @escaping @Sendable (IPSWFetchProgress) -> Void
    ) async throws -> URL {
        try HVMPaths.ensure(HVMPaths.ipswCacheDir)

        if !force, isCached(buildVersion: entry.buildVersion) {
            let dest = cachedPath(for: entry)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            Self.log.info("ipsw cache hit: build=\(entry.buildVersion, privacy: .public) size=\(size)")
            onProgress(IPSWFetchProgress(phase: .alreadyCached, receivedBytes: size, totalBytes: size))
            return dest
        }

        if force {
            Self.log.info("ipsw fetch --force: 清除 build=\(entry.buildVersion, privacy: .public)")
            try removeCache(buildVersion: entry.buildVersion)
        }

        let preResume = partialSize(buildVersion: entry.buildVersion)
        if preResume > 0 {
            Self.log.info("ipsw fetch resume: build=\(entry.buildVersion, privacy: .public) resumeFrom=\(preResume)")
        } else {
            Self.log.info("ipsw fetch fresh: build=\(entry.buildVersion, privacy: .public)")
        }

        // 第一次尝试; 内部失败若为 .rangeMismatch (416 + 大小不符) 做一次重试
        do {
            return try await attemptDownload(entry: entry, onProgress: onProgress)
        } catch _PartialResetSignal.rangeMismatch {
            // 已 truncate, 递归重新下载一次 (resumeFrom 必为 0)
            Self.log.warning("ipsw fetch 416 大小不符, truncate 后重试: build=\(entry.buildVersion, privacy: .public)")
            return try await attemptDownload(entry: entry, onProgress: onProgress)
        }
    }

    // MARK: - 内部下载

    /// 单次下载尝试 (含 If-Range / 续传). 若服务器 416 且 .partial 大小不匹配, 内部
    /// 已 truncate .partial + .meta, 抛 _PartialResetSignal.rangeMismatch 让上层重试.
    private static func attemptDownload(
        entry: IPSWCatalogEntry,
        onProgress: @escaping @Sendable (IPSWFetchProgress) -> Void
    ) async throws -> URL {
        let dest = cachedPath(for: entry)
        let partial = partialPath(buildVersion: entry.buildVersion)
        let metaPath = partialMetaPath(buildVersion: entry.buildVersion)

        let resumeFrom: Int64 = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let savedMeta: _PartialMeta? = resumeFrom > 0 ? _PartialMeta.load(from: metaPath) : nil

        if resumeFrom > 0 {
            // 立刻推一帧让 UI 显示 "resuming from XX"; 真正 total 等响应再补
            onProgress(IPSWFetchProgress(phase: .downloading, receivedBytes: resumeFrom, totalBytes: nil))
        }

        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let delegate = _IPSWDownloadDelegate(
                    dest: dest,
                    partial: partial,
                    metaPath: metaPath,
                    resumeFrom: resumeFrom,
                    onProgress: onProgress,
                    continuation: cont
                )
                // 关掉 cache (IPSW 数 GiB 不该进 URLCache), 不走 cookies
                let cfg = URLSessionConfiguration.default
                cfg.urlCache = nil
                cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
                cfg.httpCookieStorage = nil
                cfg.allowsExpensiveNetworkAccess = true
                cfg.allowsConstrainedNetworkAccess = true
                cfg.timeoutIntervalForResource = 60 * 60 * 6   // 6h: 慢网下完整 IPSW 也允许
                let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

                let req = makeRequest(url: entry.url, resumeFrom: resumeFrom, validator: savedMeta)
                let task = session.dataTask(with: req)
                delegate.bind(session: session)
                task.resume()
            }
        } catch let signal as _PartialResetSignal {
            throw signal  // 让上层 downloadIfNeeded 截到, 自动重试
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "\(error)"))
        }
    }

    /// 装配 GET 请求: 续传时带 Range: + If-Range: 头. validator 不匹配时服务器会回 200 整文件 (走 truncate 重头), 安全 fallback.
    private static func makeRequest(url: URL, resumeFrom: Int64, validator: _PartialMeta?) -> URLRequest {
        var req = URLRequest(url: url)
        if resumeFrom > 0 {
            req.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
            if let v = validator?.bestValidator() {
                req.setValue(v, forHTTPHeaderField: "If-Range")
            }
        }
        return req
    }
}

// MARK: - Partial sidecar meta

/// .partial 旁的 sidecar 文件, 保存服务器返回的 ETag / Last-Modified, 用于 If-Range 续传校验.
struct _PartialMeta: Codable, Sendable, Equatable {
    var etag: String?
    var lastModified: String?

    /// If-Range 优先用 ETag (强校验), 退化用 Last-Modified.
    func bestValidator() -> String? {
        if let e = etag, !e.isEmpty { return e }
        if let lm = lastModified, !lm.isEmpty { return lm }
        return nil
    }

    static func load(from url: URL) -> _PartialMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(_PartialMeta.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func extract(from http: HTTPURLResponse) -> _PartialMeta {
        _PartialMeta(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}

/// 内部信号: 416 时表示本地 .partial 与远端大小不符, 已 truncate, 让 downloadIfNeeded 重试一次.
enum _PartialResetSignal: Error {
    case rangeMismatch
}

// MARK: - URLSessionDataDelegate

/// 内部下载 delegate. 自己管 .partial 文件 + Range 续传, 完成后 atomic rename 到 .ipsw.
/// URLSession 强引用 delegate, tryResume 内 finishTasksAndInvalidate 解除引用避免泄漏.
///
/// 锁保护对象: resumed / lastFireMs / fileHandle / receivedBytes / totalBytes / session.
/// data delegate 回调全部串行在 session.delegateQueue (我们不指定即默认 OperationQueue,
/// max concurrent = 1), 但出于偏执 + 跨 didFinish/didError 边界, 还是 lock 一下.
private final class _IPSWDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let dest: URL
    private let partial: URL
    private let metaPath: URL
    private let resumeFrom: Int64
    private let onProgress: @Sendable (IPSWFetchProgress) -> Void
    private let continuation: CheckedContinuation<URL, Error>

    private let lock = NSLock()
    private var resumed = false
    private var lastFireMs: Int64 = 0
    private var session: URLSession?
    private var fileHandle: FileHandle?
    /// 总累计 (含 resume 起点 + 本次新收的字节)
    private var receivedBytes: Int64
    /// 完整文件大小 (从 Content-Range / Content-Length 解析); 0 表示未知
    private var totalBytes: Int64 = 0

    init(
        dest: URL,
        partial: URL,
        metaPath: URL,
        resumeFrom: Int64,
        onProgress: @escaping @Sendable (IPSWFetchProgress) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.dest = dest
        self.partial = partial
        self.metaPath = metaPath
        self.resumeFrom = resumeFrom
        self.receivedBytes = resumeFrom
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func bind(session: URLSession) {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    private func tryResume(_ result: Result<URL, Error>) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let s = session
        session = nil
        // 出错时关 fileHandle 但保留 .partial 给下次续传; 成功路径在 didCompleteWithError 已关
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
        switch result {
        case .success(let u): continuation.resume(returning: u)
        case .failure(let e): continuation.resume(throwing: e)
        }
        s?.finishTasksAndInvalidate()
    }

    // MARK: URLSessionDataDelegate — response 阶段

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            tryResume(.failure(URLError(.badServerResponse)))
            return
        }

        switch http.statusCode {
        case 200:
            // 服务器忽略 Range (我们没发或 If-Range 不匹配) — 从头开始, truncate .partial
            // 顺便把新的 ETag/Last-Modified 写到 .meta sidecar
            handle200(http: http, completionHandler: completionHandler)
        case 206:
            // Partial Content — 续传, append 到 .partial 末尾
            handle206(http: http, completionHandler: completionHandler)
        case 416:
            // Range Not Satisfiable — 需校验是否真的是 "已下完", 不能无脑 promote.
            // Apple HTTP 标准: 416 响应里 Content-Range: bytes */<total>, total 表示完整文件大小.
            completionHandler(.cancel)
            handle416(http: http)
        default:
            completionHandler(.cancel)
            tryResume(.failure(HVMError.install(.ipswDownloadFailed(
                reason: "HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
            ))))
        }
    }

    private func handle200(http: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let fh = try FileHandle(forWritingTo: partial)
            // 刷新 .meta sidecar (新文件可能换了 validator)
            _PartialMeta.extract(from: http).save(to: metaPath)
            lock.lock()
            self.fileHandle = fh
            self.receivedBytes = 0  // 服务器从头给, 重置计数
            self.totalBytes = max(0, http.expectedContentLength)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            tryResume(.failure(error))
        }
    }

    private func handle206(http: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: partial)
            try fh.seekToEnd()
            // 解析 Content-Range: "bytes 1234-9999/10000" 拿总大小; 否则用 resumeFrom + expectedContentLength 估
            var total: Int64 = 0
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = cr.lastIndex(of: "/") {
                let tail = cr[cr.index(after: slash)...]
                if let t = Int64(tail) { total = t }
            }
            if total <= 0 {
                let exp = max(0, http.expectedContentLength)
                total = resumeFrom + exp
            }
            // 首次没存 .meta 的话, 这里补上 (服务器在 206 里也会带 ETag)
            let meta = _PartialMeta.extract(from: http)
            if meta.bestValidator() != nil { meta.save(to: metaPath) }
            lock.lock()
            self.fileHandle = fh
            self.totalBytes = total
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            tryResume(.failure(error))
        }
    }

    /// 416: 校验 .partial 大小是否等于服务器报告的完整文件大小.
    /// 等于 → promote (.partial 就是完整文件); 不等 → truncate + 抛 _PartialResetSignal,
    /// 让 downloadIfNeeded 自动重试一次.
    private func handle416(http: HTTPURLResponse) {
        var total: Int64 = -1
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/") {
            let tail = cr[cr.index(after: slash)...]
            if let t = Int64(tail) { total = t }
        }
        let partialSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0

        if total > 0 && partialSize == total {
            // 真的已下完, 安全 promote
            promotePartialAsCompleted(expectedSize: total)
            return
        }

        // 不一致: truncate + meta, 让上层自动重下
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: metaPath)
        tryResume(.failure(_PartialResetSignal.rangeMismatch))
    }

    /// .partial 大小已确认 == 服务器 total, atomic rename 成 .ipsw, 清 .meta.
    private func promotePartialAsCompleted(expectedSize: Int64) {
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: partial, to: dest)
            try? FileManager.default.removeItem(at: metaPath)
            onProgress(IPSWFetchProgress(phase: .completed, receivedBytes: expectedSize, totalBytes: expectedSize))
            tryResume(.success(dest))
        } catch {
            tryResume(.failure(error))
        }
    }

    // MARK: URLSessionDataDelegate — 数据 + 完成

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // 写文件 + 推进度 (节流 100ms)
        do {
            lock.lock()
            // delegate 失败后可能仍有少量回调残留, fileHandle=nil 时 silent drop
            guard let fh = fileHandle else { lock.unlock(); return }
            try fh.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            let r = receivedBytes
            let t = totalBytes
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let shouldFire = now - lastFireMs >= 100
            if shouldFire { lastFireMs = now }
            lock.unlock()
            if shouldFire {
                onProgress(IPSWFetchProgress(
                    phase: .downloading,
                    receivedBytes: r,
                    totalBytes: t > 0 ? t : nil
                ))
            }
        } catch {
            // 写盘失败致命 (磁盘满 / 权限问题), 终止 task
            tryResume(.failure(error))
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            // 失败 — 关 fileHandle 但保留 .partial (下次续传)
            tryResume(.failure(e))
            return
        }

        // 成功 — flush + close + atomic rename .partial -> .ipsw
        lock.lock()
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        let final = receivedBytes
        lock.unlock()

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: partial, to: dest)
            try? FileManager.default.removeItem(at: metaPath)  // 完成态无须 sidecar
            onProgress(IPSWFetchProgress(phase: .completed, receivedBytes: final, totalBytes: final))
            tryResume(.success(dest))
        } catch {
            tryResume(.failure(error))
        }
    }
}
