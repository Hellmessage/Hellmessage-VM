// HVMUtils/ResumableDownloader.swift
// 通用 HTTP 断点续传下载器, 从 IPSWFetcher 抽离泛化, 给 OS 镜像下载 / IPSW / 任何
// 大文件下载场景共用. 不绑死任何业务语义.
//
// === 设计 ===
//
// 不用 URLSessionDownloadTask + resumeData (跨进程不可靠 / tmp 路径不可控). 自己管文件:
//   1. 下载中文件名 <dest>.partial; 完成后原子 rename → <dest>
//   2. 首次响应时把服务器的 ETag / Last-Modified 写到 sidecar <dest>.partial.meta
//   3. 下次 download 检查 .partial size > 0 → 发 Range: bytes=N- + If-Range: <validator>
//   4. 服务器响应:
//      - 206 Partial Content → seek-to-end 后 append (validator 仍匹配)
//      - 200 OK              → 服务器忽略 Range 或 If-Range 不匹配 (文件变了),
//                              truncate .partial 从头开始, 同时刷新 .meta
//      - 416 Range Not Satisfiable → 校验 Content-Range: */<total> 中的 total
//                                    与本地 .partial size 一致 → promote (已下完);
//                                    不一致 → truncate + auto-retry 一次 (resumeFrom=0)
//   5. App 崩溃 / 系统重启 / kill -9 都不影响, .partial + .meta 留在原目录,
//      下次 download 自动续传, validator 不匹配会安全 fallback 到全新下载
//
// 服务器要求: 静态资源 + 支持 Range + If-Range. 公共 CDN (Apple / cdimage.ubuntu.com /
// cdimage.debian.org / fedoraproject.org / rockylinux.org / opensuse.org / Microsoft) 普遍满足.
//
// === 调用约定 ===
//
// - onProgress 在后台 URLSession delegate queue 调用, 不要直接动 UI; UI 调用方应自己
//   调度回主线程. 频率为 100ms 节流 + 速率/ETA 用 5s 滑动窗口
// - 抛 DownloadError; 调用方按需映射成自己的领域错误 (HVMError.install / .config 等)
// - 自动处理 416 重试 (一次), 二次失败抛出
// - 不做 SHA256 校验 (调用方在拿到 dest 后自验, 因为 catalog 里有 expected hash 时才有意义)

import Foundation
import HVMCore

// MARK: - 公开类型

/// 通用下载进度. 与 IPSWFetchProgress 字段对齐, 调用方可直接 1:1 映射.
public struct DownloadProgress: Sendable, Equatable {
    /// 已收字节 (含 resume 起点)
    public let receivedBytes: Int64
    /// 完整文件大小; nil = 服务器未告知 / 起步阶段
    public let totalBytes: Int64?
    /// 当前速率 (bytes/s); nil = 样本不够 (起步阶段)
    public let bytesPerSecond: Double?
    /// 剩余秒数; nil = 速率或 totalBytes 未知
    public let etaSeconds: Double?

    public init(
        receivedBytes: Int64,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil
    ) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
    }
}

/// 下载层错误. 调用方按需翻译成业务错误.
public enum DownloadError: Error, Sendable, Equatable {
    /// HTTP 状态码非 2xx (e.g. 404, 500)
    case httpStatus(Int)
    /// 服务器响应不是 HTTPURLResponse 或缺关键字段
    case badResponse(String)
    /// 写盘失败 (磁盘满 / 权限问题 / 路径不存在)
    case writeFailed(String)
    /// 其他 (URLError 等)
    case other(String)
}

extension DownloadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .httpStatus(let code):
            return "HTTP \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))"
        case .badResponse(let s): return "bad response: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        case .other(let s):       return s
        }
    }
}

// MARK: - 主入口

public enum ResumableDownloader {
    private static let log = HVMLog.logger("utils.download")

    /// 通用断点续传下载.
    ///
    /// 行为:
    /// - 检查 `dest` 是否已存在 + size > 0: **不**自动跳过 (调用方决定缓存策略); 这里只下载.
    /// - 派生 `<dest>.partial` 与 `<dest>.partial.meta`, 按 If-Range 续传.
    /// - 完成后 atomic rename `<dest>.partial` → `<dest>`, 删 `.meta` sidecar.
    ///
    /// - Parameters:
    ///   - url: 远程下载地址 (https/http)
    ///   - dest: 目标本地路径 (调用方保证父目录存在)
    ///   - timeoutForResource: 单次下载总超时 (秒), 默认 6 小时 (适用大 IPSW / ISO)
    ///   - onProgress: 进度回调 (后台线程, 100ms 节流). 失败 / 完成时也会有 final tick (completed=true 则 receivedBytes==totalBytes)
    /// - Returns: 完成后的 dest URL (与入参相同)
    @discardableResult
    public static func download(
        from url: URL,
        to dest: URL,
        timeoutForResource: TimeInterval = 6 * 3600,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        // 第一次尝试; 内部失败若为 .rangeMismatch (416 + 大小不符) 做一次重试
        do {
            return try await attemptDownload(
                url: url, dest: dest, timeout: timeoutForResource, onProgress: onProgress
            )
        } catch _PartialResetSignal.rangeMismatch {
            Self.log.warning("download 416 大小不符, truncate 后重试: \(dest.lastPathComponent, privacy: .public)")
            return try await attemptDownload(
                url: url, dest: dest, timeout: timeoutForResource, onProgress: onProgress
            )
        }
    }

    /// 派生 .partial 路径
    public static func partialPath(for dest: URL) -> URL {
        dest.appendingPathExtension("partial")
    }

    /// 派生 .partial.meta sidecar 路径
    public static func partialMetaPath(for dest: URL) -> URL {
        partialPath(for: dest).appendingPathExtension("meta")
    }

    /// 已经写入磁盘的半成品大小 (bytes); 不存在返 0
    public static func partialSize(for dest: URL) -> Int64 {
        let p = partialPath(for: dest).path
        return (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
    }

    /// 删除 dest + .partial + .partial.meta (幂等). 用于 force-redownload / 清缓存场景.
    public static func clearAll(at dest: URL) throws {
        let paths = [dest, partialPath(for: dest), partialMetaPath(for: dest)]
        for p in paths where FileManager.default.fileExists(atPath: p.path) {
            do {
                try FileManager.default.removeItem(at: p)
            } catch {
                throw DownloadError.writeFailed("rm \(p.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - 内部下载

    private static func attemptDownload(
        url: URL,
        dest: URL,
        timeout: TimeInterval,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let partial = partialPath(for: dest)
        let metaPath = partialMetaPath(for: dest)

        let resumeFrom: Int64 = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let savedMeta: _PartialMeta? = resumeFrom > 0 ? _PartialMeta.load(from: metaPath) : nil

        if resumeFrom > 0 {
            Self.log.info("download resume: \(dest.lastPathComponent, privacy: .public) resumeFrom=\(resumeFrom)")
            // 立刻推一帧让 UI 显示 "resuming from XX"; 真正 total 等响应再补
            onProgress(DownloadProgress(receivedBytes: resumeFrom, totalBytes: nil))
        } else {
            Self.log.info("download fresh: \(dest.lastPathComponent, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        }

        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let delegate = _DownloadDelegate(
                    dest: dest,
                    partial: partial,
                    metaPath: metaPath,
                    resumeFrom: resumeFrom,
                    onProgress: onProgress,
                    continuation: cont
                )
                let cfg = URLSessionConfiguration.default
                cfg.urlCache = nil
                cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
                cfg.httpCookieStorage = nil
                cfg.allowsExpensiveNetworkAccess = true
                cfg.allowsConstrainedNetworkAccess = true
                cfg.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)

                let req = makeRequest(url: url, resumeFrom: resumeFrom, validator: savedMeta)
                let task = session.dataTask(with: req)
                delegate.bind(session: session)
                task.resume()
            }
        } catch let signal as _PartialResetSignal {
            throw signal
        } catch let e as DownloadError {
            throw e
        } catch {
            throw DownloadError.other("\(error)")
        }
    }

    /// 装配 GET 请求: 续传时带 Range: + If-Range:. validator 不匹配时服务器回 200 整文件 (走 truncate 重头), 安全 fallback.
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

// MARK: - .partial.meta sidecar

/// .partial 旁的 sidecar, 保存服务器返回的 ETag / Last-Modified, 用于 If-Range 续传校验.
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

/// 416 时表示本地 .partial 与远端大小不符, 已 truncate, 让 download 重试一次.
enum _PartialResetSignal: Error {
    case rangeMismatch
}

// MARK: - URLSessionDataDelegate

/// 内部下载 delegate. 自己管 .partial 文件 + Range 续传, 完成后 atomic rename → dest.
/// URLSession 强引用 delegate, tryResume 内 finishTasksAndInvalidate 解除引用避免泄漏.
private final class _DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let dest: URL
    private let partial: URL
    private let metaPath: URL
    private let resumeFrom: Int64
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let continuation: CheckedContinuation<URL, Error>

    private let lock = NSLock()
    private var resumed = false
    private var lastFireMs: Int64 = 0
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64
    private var totalBytes: Int64 = 0
    private var rateSamples: [(Int64, Int64)] = []
    private static let rateWindowMs: Int64 = 5_000

    init(
        dest: URL,
        partial: URL,
        metaPath: URL,
        resumeFrom: Int64,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
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
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
        switch result {
        case .success(let u): continuation.resume(returning: u)
        case .failure(let e): continuation.resume(throwing: e)
        }
        s?.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            tryResume(.failure(DownloadError.badResponse("non-HTTP response")))
            return
        }

        switch http.statusCode {
        case 200:
            handle200(http: http, completionHandler: completionHandler)
        case 206:
            handle206(http: http, completionHandler: completionHandler)
        case 416:
            completionHandler(.cancel)
            handle416(http: http)
        default:
            completionHandler(.cancel)
            tryResume(.failure(DownloadError.httpStatus(http.statusCode)))
        }
    }

    private func handle200(http: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let fh = try FileHandle(forWritingTo: partial)
            _PartialMeta.extract(from: http).save(to: metaPath)
            lock.lock()
            self.fileHandle = fh
            self.receivedBytes = 0
            self.totalBytes = max(0, http.expectedContentLength)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            tryResume(.failure(DownloadError.writeFailed("\(error)")))
        }
    }

    private func handle206(http: HTTPURLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: partial)
            try fh.seekToEnd()
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
            let meta = _PartialMeta.extract(from: http)
            if meta.bestValidator() != nil { meta.save(to: metaPath) }
            lock.lock()
            self.fileHandle = fh
            self.totalBytes = total
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            tryResume(.failure(DownloadError.writeFailed("\(error)")))
        }
    }

    private func handle416(http: HTTPURLResponse) {
        var total: Int64 = -1
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/") {
            let tail = cr[cr.index(after: slash)...]
            if let t = Int64(tail) { total = t }
        }
        let partialSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0

        if total > 0 && partialSize == total {
            promotePartialAsCompleted(expectedSize: total)
            return
        }

        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: metaPath)
        tryResume(.failure(_PartialResetSignal.rangeMismatch))
    }

    private func promotePartialAsCompleted(expectedSize: Int64) {
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: partial, to: dest)
            try? FileManager.default.removeItem(at: metaPath)
            onProgress(DownloadProgress(receivedBytes: expectedSize, totalBytes: expectedSize))
            tryResume(.success(dest))
        } catch {
            tryResume(.failure(DownloadError.writeFailed("\(error)")))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            lock.lock()
            guard let fh = fileHandle else { lock.unlock(); return }
            try fh.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            let r = receivedBytes
            let t = totalBytes
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let shouldFire = now - lastFireMs >= 100
            var rate: Double? = nil
            var eta: Double? = nil
            if shouldFire {
                lastFireMs = now
                rateSamples.append((now, r))
                while let first = rateSamples.first, now - first.0 > Self.rateWindowMs {
                    rateSamples.removeFirst()
                }
                if let oldest = rateSamples.first,
                   rateSamples.count >= 2 {
                    let dt = Double(now - oldest.0) / 1000.0
                    let db = Double(r - oldest.1)
                    if dt >= 0.5, db > 0 {
                        rate = db / dt
                        if let rate, t > 0, r < t {
                            eta = Double(t - r) / rate
                        }
                    }
                }
            }
            lock.unlock()
            if shouldFire {
                onProgress(DownloadProgress(
                    receivedBytes: r,
                    totalBytes: t > 0 ? t : nil,
                    bytesPerSecond: rate,
                    etaSeconds: eta
                ))
            }
        } catch {
            tryResume(.failure(DownloadError.writeFailed("\(error)")))
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            tryResume(.failure(DownloadError.other("\(e)")))
            return
        }

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
            try? FileManager.default.removeItem(at: metaPath)
            onProgress(DownloadProgress(receivedBytes: final, totalBytes: final))
            tryResume(.success(dest))
        } catch {
            tryResume(.failure(DownloadError.writeFailed("\(error)")))
        }
    }
}
