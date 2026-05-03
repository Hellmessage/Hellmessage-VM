// HVMInstall/IPSWFetcher.swift
// IPSW 下载器. 走 VZMacOSRestoreImage.fetchLatestSupported 拿最新远程 URL,
// 内部委托给 HVMUtils.ResumableDownloader 做断点续传 + atomic rename.
//
// 决策 J1: 不走 Apple SUCatalog (XML 解析、需手动算 hash), VZ 直接给我们 IPSW URL,
// 配合 RestoreImageHandle 后续校验 mostFeaturefulSupportedConfiguration 已足够.
//
// 缓存约束:
//   - 文件名固定 <buildVersion>.ipsw, build 一致即认为同一份
//   - 已存在 + 大小 > 0 视为可用; 上层 (RestoreImageHandle.load) 会做内容校验
//   - --force 同时清 .ipsw + .partial + .meta (走 ResumableDownloader.clearAll)
//   - rm <build> 也同时清三者
//
// 详见 docs/GUEST_OS_INSTALL.md "IPSW 缓存管理".

import Foundation
@preconcurrency import Virtualization
import HVMCore
import HVMUtils

// MARK: - 公开类型

/// 远程 IPSW 元信息.
/// - resolveLatest 走 VZMacOSRestoreImage 的会含 minCPU/minMemoryMiB (从 mostFeaturefulSupportedConfiguration);
/// - fetchCatalog 走 mesu plist 的不含 (省一次 IPSW load), 只有 build/version/url/postingDate;
/// - resolveURL (用户自带 URL) 也只有 url + 占位 build.
public struct IPSWCatalogEntry: Sendable, Equatable, Codable {
    /// 例 "24A335"
    public let buildVersion: String
    /// 例 "15.0.1"
    public let osVersion: String
    /// 远程下载 URL (https://updates.cdn-apple.com/...)
    public let url: URL
    /// IPSW 推荐的最低 CPU 数 (仅 resolveLatest 已知)
    public let minCPU: Int?
    /// IPSW 推荐的最低内存 (MiB) (仅 resolveLatest 已知)
    public let minMemoryMiB: UInt64?
    /// catalog 里的发布日期 (mesu PostingDate); resolveLatest / resolveURL 时为 nil
    public let postingDate: Date?

    public init(
        buildVersion: String,
        osVersion: String,
        url: URL,
        minCPU: Int? = nil,
        minMemoryMiB: UInt64? = nil,
        postingDate: Date? = nil
    ) {
        self.buildVersion = buildVersion
        self.osVersion = osVersion
        self.url = url
        self.minCPU = minCPU
        self.minMemoryMiB = minMemoryMiB
        self.postingDate = postingDate
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
    /// 当前下载速率 (bytes/sec). nil = 样本不够 (起步阶段或非下载阶段)
    public let bytesPerSecond: Double?
    /// 预计还需秒数. nil = 速率或 totalBytes 未知
    public let etaSeconds: Double?

    public init(
        phase: IPSWFetchPhase,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        etaSeconds: Double? = nil
    ) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
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

    /// macOS IPSW catalog 数据源 — 用 ipsw.me 第三方 API.
    ///
    /// 为什么不用 Apple 的 mesu (https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml):
    /// 实测 mesu 只发布"当前最新版"的 IPSW (例如 VirtualMac2,1 下面只有一个 25E253 entry),
    /// 没有历史版本, "选择版本" UX 价值约等于 0.
    ///
    /// ipsw.me 是社区维护的 IPSW 索引 API, 稳定多年, 免认证, 含全量历史版本.
    /// 端点: https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw
    /// 返回 JSON, 字段含 buildid / version / url / releasedate / filesize / sha256sum / signed.
    /// signed=false 不影响 VZ guest (VZ 不强制 IPSW 当前签名状态).
    public static let catalogURL = URL(
        string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw"
    )!

    /// 查询 Apple 当前推荐的最新 macOS guest IPSW. 不下载, 仅返回元信息.
    /// 失败抛 .install(.ipswDownloadFailed)
    public static func resolveLatest() async throws -> IPSWCatalogEntry {
        Self.log.info("resolveLatest: VZMacOSRestoreImage.fetchLatestSupported")
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

    /// 拉 ipsw.me 上 VirtualMac2,1 的全量 IPSW 列表. 按 releasedate 倒序排序.
    /// 失败抛 .install(.ipswDownloadFailed).
    public static func fetchCatalog() async throws -> [IPSWCatalogEntry] {
        Self.log.info("fetchCatalog: \(Self.catalogURL.absoluteString, privacy: .public)")

        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: Self.catalogURL)
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "catalog GET 失败: \(error)"))
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HVMError.install(.ipswDownloadFailed(reason: "catalog HTTP \(code)"))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let s = try c.decode(String.self)
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso8601NoFrac = ISO8601DateFormatter()
            iso8601NoFrac.formatOptions = [.withInternetDateTime]
            if let v = iso8601.date(from: s) { return v }
            if let v = iso8601NoFrac.date(from: s) { return v }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析日期: \(s)")
        }

        let parsed: _IpswMeResponse
        do {
            parsed = try decoder.decode(_IpswMeResponse.self, from: data)
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "catalog JSON 解析失败: \(error)"))
        }

        let entries = parsed.firmwares.compactMap { fw -> IPSWCatalogEntry? in
            guard let url = URL(string: fw.url) else { return nil }
            return IPSWCatalogEntry(
                buildVersion: fw.buildid,
                osVersion: fw.version,
                url: url,
                minCPU: nil,
                minMemoryMiB: nil,
                postingDate: fw.releasedate
            )
        }

        var dedup: [String: IPSWCatalogEntry] = [:]
        for e in entries {
            if let prev = dedup[e.buildVersion],
               (prev.postingDate ?? .distantPast) >= (e.postingDate ?? .distantPast) {
                continue
            }
            dedup[e.buildVersion] = e
        }
        let sorted = Array(dedup.values).sorted {
            ($0.postingDate ?? .distantPast) > ($1.postingDate ?? .distantPast)
        }
        Self.log.info("fetchCatalog: 解析得 \(sorted.count) 条 VZ-compatible IPSW")
        return sorted
    }

    /// 在 catalog 里按 buildVersion 查具体条目. 找不到抛 .ipswUnsupported.
    public static func resolveBuild(_ buildVersion: String) async throws -> IPSWCatalogEntry {
        let catalog = try await fetchCatalog()
        guard let entry = catalog.first(where: { $0.buildVersion == buildVersion }) else {
            throw HVMError.install(.ipswUnsupported(
                reason: "build \(buildVersion) 不在 Apple catalog 里. 试 hvm-cli ipsw catalog 看可用 build"
            ))
        }
        Self.log.info("resolveBuild: build=\(entry.buildVersion, privacy: .public) os=\(entry.osVersion, privacy: .public)")
        return entry
    }

    /// 用户自带 URL. 不校验 URL 内容, 仅构造 entry.
    /// build 用 URL 文件名兜底 (用于 cache 命名), 真实下载完成后由 RestoreImageHandle.load 校验.
    public static func resolveURL(_ url: URL) -> IPSWCatalogEntry {
        let stem = url.deletingPathExtension().lastPathComponent
        Self.log.info("resolveURL: url=\(url.absoluteString, privacy: .public) build=\(stem, privacy: .public)")
        return IPSWCatalogEntry(
            buildVersion: stem.isEmpty ? "custom" : stem,
            osVersion: "?",
            url: url
        )
    }

    /// 给定 entry 计算其在 cache 内应有的本地路径 (不保证存在).
    public static func cachedPath(for entry: IPSWCatalogEntry) -> URL {
        cachedPath(buildVersion: entry.buildVersion)
    }

    public static func cachedPath(buildVersion: String) -> URL {
        HVMPaths.ipswCacheDir.appendingPathComponent("\(buildVersion).ipsw")
    }

    /// 半成品路径. 完成后 atomic rename 到 cachedPath. 内部委托 ResumableDownloader.
    public static func partialPath(buildVersion: String) -> URL {
        ResumableDownloader.partialPath(for: cachedPath(buildVersion: buildVersion))
    }

    /// 半成品 sidecar meta 路径 (含 ETag / Last-Modified, 用于 If-Range 校验).
    public static func partialMetaPath(buildVersion: String) -> URL {
        ResumableDownloader.partialMetaPath(for: cachedPath(buildVersion: buildVersion))
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
        ResumableDownloader.partialSize(for: cachedPath(buildVersion: buildVersion))
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

    /// 删除单个缓存 (含 .partial + .meta sidecar, 走 ResumableDownloader.clearAll). 不存在静默通过.
    public static func removeCache(buildVersion: String) throws {
        do {
            try ResumableDownloader.clearAll(at: cachedPath(buildVersion: buildVersion))
        } catch let e as DownloadError {
            throw HVMError.install(.ipswDownloadFailed(reason: "rm cache build=\(buildVersion): \(e)"))
        }
    }

    /// 清空整个 cache 目录.
    public static func clearAllCache() throws {
        for item in listCache() {
            try removeCache(buildVersion: item.buildVersion)
        }
    }

    /// 下载 entry 指向的 IPSW 到 cache. 自动断点续传 (有 .partial 即续传, 无则全新下).
    /// - 已缓存 (.ipsw 存在 + size>0): 跳过, 推送 .alreadyCached
    /// - force: 同时清 .ipsw + .partial + .meta, 全新下载
    /// - onProgress: 调用上下文 = 后台 URLSession delegate queue, 不要直接动 UI
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

        let dest = cachedPath(for: entry)

        do {
            let result = try await ResumableDownloader.download(
                from: entry.url,
                to: dest
            ) { p in
                // 中间所有 tick 都 emit .downloading; .completed 由本函数返回后统一 emit
                onProgress(IPSWFetchProgress(
                    phase: .downloading,
                    receivedBytes: p.receivedBytes,
                    totalBytes: p.totalBytes,
                    bytesPerSecond: p.bytesPerSecond,
                    etaSeconds: p.etaSeconds
                ))
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int64) ?? 0
            onProgress(IPSWFetchProgress(phase: .completed, receivedBytes: size, totalBytes: size))
            return result
        } catch let e as DownloadError {
            throw HVMError.install(.ipswDownloadFailed(reason: "\(e)"))
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "\(error)"))
        }
    }
}

// MARK: - ipsw.me JSON schema

/// ipsw.me /v4/device/<id>?type=ipsw 的 JSON 响应.
private struct _IpswMeResponse: Decodable {
    let firmwares: [_IpswMeFirmware]
}

private struct _IpswMeFirmware: Decodable {
    let buildid: String
    let version: String
    let url: String
    let releasedate: Date?
    let filesize: Int64?
    let signed: Bool?
}
