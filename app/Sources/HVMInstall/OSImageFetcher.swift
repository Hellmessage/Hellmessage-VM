// HVMInstall/OSImageFetcher.swift
// Linux / Windows guest ISO 自动下载器. 入口分两类:
//   - downloadIfNeeded(entry:): 走 OSImageCatalog 内置条目 (有 expected SHA256 时下载后校验)
//   - downloadCustom(url:):     走用户自填 URL (无校验, Win11 ISO 等场景兜底)
//
// 内部委托 HVMUtils.ResumableDownloader 做断点续传 + atomic rename, 完成后 (if entry.sha256 != nil)
// 流式算 SHA256 校验. 校验失败删本地文件抛错, 避免脏数据次次重下.
//
// 缓存布局:
//   ~/Library/Application Support/HVM/cache/os-images/
//     ├── ubuntu/   <iso 文件名 含小版本号>
//     ├── debian/
//     ├── fedora/
//     ├── alpine/
//     ├── rocky/
//     ├── opensuse/
//     └── custom/   <用户 URL 文件名>
//
// VM 创建时 ISO 路径**不复制进 bundle**, 只在 VMConfig.iso 字段写绝对路径
// (跟 hvm-cli create --iso 行为一致).

import Foundation
import CryptoKit
import HVMCore
import HVMUtils

// MARK: - 公开类型

public enum OSImageFetchPhase: String, Sendable, Equatable, Codable {
    case downloading     // URLSession 拉数据
    case verifying       // 算 SHA256 校验 (大文件可能要几秒到十几秒)
    case completed       // 已落到 cache + (如有 SHA) 校验通过
    case alreadyCached   // 缓存已命中, 跳过下载
}

public struct OSImageFetchProgress: Sendable, Equatable {
    public let phase: OSImageFetchPhase
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?
    public let etaSeconds: Double?

    public init(
        phase: OSImageFetchPhase,
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

/// 已缓存的 OS image (本地文件)
public struct OSImageCacheItem: Sendable, Equatable, Codable {
    public let entryId: String?       // 命中 catalog 时填; custom 下载为 nil
    public let family: OSImageFamily
    public let path: String
    public let sizeBytes: Int64

    public init(entryId: String?, family: OSImageFamily, path: String, sizeBytes: Int64) {
        self.entryId = entryId
        self.family = family
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

// MARK: - 主实现

public enum OSImageFetcher {
    private static let log = HVMLog.logger("install.osimage")

    // MARK: 路径

    /// 给定 family 的 cache 子目录
    public static func cacheDir(for family: OSImageFamily) -> URL {
        HVMPaths.osImagesCacheDir.appendingPathComponent(family.rawValue, isDirectory: true)
    }

    /// 给定 entry 的本地缓存路径
    public static func cachedPath(for entry: OSImageEntry) -> URL {
        cacheDir(for: entry.family).appendingPathComponent(entry.cacheFileName)
    }

    /// 给定 custom URL 的本地缓存路径 (cache/os-images/custom/<filename>)
    public static func customCachedPath(for url: URL) -> URL {
        let name = url.lastPathComponent.isEmpty ? "custom.iso" : url.lastPathComponent
        return cacheDir(for: .custom).appendingPathComponent(name)
    }

    // MARK: 缓存查询

    public static func isCached(entry: OSImageEntry) -> Bool {
        isCached(at: cachedPath(for: entry))
    }

    public static func isCachedCustom(url: URL) -> Bool {
        isCached(at: customCachedPath(for: url))
    }

    /// 半成品大小 (bytes); 不存在返 0
    public static func partialSize(entry: OSImageEntry) -> Int64 {
        ResumableDownloader.partialSize(for: cachedPath(for: entry))
    }

    private static func isCached(at path: URL) -> Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attr[.size] as? Int64, size > 0 else {
            return false
        }
        return true
    }

    /// 删除单个 entry 缓存 (含 .partial / .meta).
    public static func removeCache(entry: OSImageEntry) throws {
        do {
            try ResumableDownloader.clearAll(at: cachedPath(for: entry))
        } catch let e as DownloadError {
            throw HVMError.install(.ipswDownloadFailed(reason: "rm os-image \(entry.id): \(e)"))
        }
    }

    public static func removeCustomCache(url: URL) throws {
        do {
            try ResumableDownloader.clearAll(at: customCachedPath(for: url))
        } catch let e as DownloadError {
            throw HVMError.install(.ipswDownloadFailed(reason: "rm custom \(url.lastPathComponent): \(e)"))
        }
    }

    /// 列出所有已缓存 OS image. family=nil 时列全部.
    public static func listCache(family: OSImageFamily? = nil) -> [OSImageCacheItem] {
        let families = family.map { [$0] } ?? OSImageFamily.allCases
        var out: [OSImageCacheItem] = []
        for fam in families {
            let dir = cacheDir(for: fam)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ext == "iso" || ext == "img" else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                let entryId = OSImageCatalog.entries(for: fam).first { $0.cacheFileName == url.lastPathComponent }?.id
                out.append(OSImageCacheItem(entryId: entryId, family: fam, path: url.path, sizeBytes: size))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: 下载主入口

    /// 下载 catalog entry. 自动断点续传 + (如 entry.sha256 != nil) SHA256 校验.
    @discardableResult
    public static func downloadIfNeeded(
        entry: OSImageEntry,
        force: Bool = false,
        onProgress: @escaping @Sendable (OSImageFetchProgress) -> Void
    ) async throws -> URL {
        try HVMPaths.ensure(cacheDir(for: entry.family))

        if !force, isCached(entry: entry) {
            let dest = cachedPath(for: entry)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            Self.log.info("os-image cache hit: id=\(entry.id, privacy: .public) size=\(size)")
            onProgress(OSImageFetchProgress(phase: .alreadyCached, receivedBytes: size, totalBytes: size))
            return dest
        }

        if force {
            Self.log.info("os-image fetch --force: id=\(entry.id, privacy: .public)")
            try removeCache(entry: entry)
        }

        let dest = cachedPath(for: entry)
        let resumeFrom = ResumableDownloader.partialSize(for: dest)
        if resumeFrom > 0 {
            Self.log.info("os-image fetch resume: id=\(entry.id, privacy: .public) from=\(resumeFrom)")
        }

        return try await downloadAndVerify(
            url: entry.url, dest: dest, expectedSha256: entry.sha256,
            entryLabel: entry.id, onProgress: onProgress
        )
    }

    /// 下载用户自填 URL. 不做 SHA256 校验 (URL 来源未知).
    @discardableResult
    public static func downloadCustom(
        url: URL,
        force: Bool = false,
        onProgress: @escaping @Sendable (OSImageFetchProgress) -> Void
    ) async throws -> URL {
        try HVMPaths.ensure(cacheDir(for: .custom))

        let dest = customCachedPath(for: url)

        if !force, isCached(at: dest) {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            Self.log.info("os-image custom cache hit: \(dest.lastPathComponent, privacy: .public) size=\(size)")
            onProgress(OSImageFetchProgress(phase: .alreadyCached, receivedBytes: size, totalBytes: size))
            return dest
        }

        if force {
            try removeCustomCache(url: url)
        }

        return try await downloadAndVerify(
            url: url, dest: dest, expectedSha256: nil,
            entryLabel: "custom:\(dest.lastPathComponent)", onProgress: onProgress
        )
    }

    // MARK: - 内部

    private static func downloadAndVerify(
        url: URL,
        dest: URL,
        expectedSha256: String?,
        entryLabel: String,
        onProgress: @escaping @Sendable (OSImageFetchProgress) -> Void
    ) async throws -> URL {
        // 1. 下载 (走 ResumableDownloader)
        do {
            try await ResumableDownloader.download(from: url, to: dest) { p in
                onProgress(OSImageFetchProgress(
                    phase: .downloading,
                    receivedBytes: p.receivedBytes,
                    totalBytes: p.totalBytes,
                    bytesPerSecond: p.bytesPerSecond,
                    etaSeconds: p.etaSeconds
                ))
            }
        } catch let e as DownloadError {
            throw HVMError.install(.ipswDownloadFailed(reason: "[\(entryLabel)] download: \(e)"))
        } catch {
            throw HVMError.install(.ipswDownloadFailed(reason: "[\(entryLabel)] download: \(error)"))
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0

        // 2. (如有 expected SHA) 流式 hash 校验
        if let expected = expectedSha256 {
            onProgress(OSImageFetchProgress(phase: .verifying, receivedBytes: size, totalBytes: size))
            let actual: String
            do {
                actual = try await sha256OfFile(dest)
            } catch {
                throw HVMError.install(.ipswDownloadFailed(reason: "[\(entryLabel)] SHA256 read: \(error)"))
            }
            let actualLower = actual.lowercased()
            let expectedLower = expected.lowercased()
            if actualLower != expectedLower {
                Self.log.error("os-image sha mismatch: id=\(entryLabel, privacy: .public) expected=\(expectedLower, privacy: .public) actual=\(actualLower, privacy: .public)")
                // 删损坏文件防止用户次次重下命中"缓存"得到同一坏文件
                try? FileManager.default.removeItem(at: dest)
                throw HVMError.install(.ipswDownloadFailed(reason:
                    "[\(entryLabel)] SHA256 校验失败. 期望 \(expectedLower), 实际 \(actualLower). " +
                    "可能服务器侧 ISO 已升级到新版本, 请到 OSImageCatalog 更新 entry; " +
                    "或者下载途中数据损坏, 重试一次."
                ))
            }
            Self.log.info("os-image sha ok: id=\(entryLabel, privacy: .public) sha=\(actualLower, privacy: .public)")
        }

        onProgress(OSImageFetchProgress(phase: .completed, receivedBytes: size, totalBytes: size))
        return dest
    }

    /// 流式算文件 SHA256 (1 MiB chunk). 给 catalog 后置校验用.
    /// 跑在 detached Task 避免阻塞 caller actor; 大文件 (3GB) 大约 5-10s.
    private static func sha256OfFile(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            var hasher = SHA256()
            while let chunk = try fh.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
