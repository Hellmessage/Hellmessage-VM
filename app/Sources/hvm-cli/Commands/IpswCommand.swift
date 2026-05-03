// IpswCommand.swift
// hvm-cli ipsw — IPSW 缓存管理 + 下载入口.
//
// 子命令:
//   latest        查询 Apple 当前推荐的 macOS guest IPSW (不下载, 仅元信息)
//   fetch         下载 IPSW 到 ~/Library/Application Support/HVM/cache/ipsw/
//   list          列出已缓存的 IPSW
//   rm <build|all> 删除单个或全部缓存
//
// 详见 docs/GUEST_OS_INSTALL.md "IPSW 缓存管理" / docs/CLI.md "ipsw"

import ArgumentParser
import Foundation
import HVMCore
import HVMInstall
import HVMUtils

struct IpswCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipsw",
        abstract: "IPSW 下载与缓存管理 (~/Library/Application Support/HVM/cache/ipsw)",
        subcommands: [
            IpswLatestCommand.self,
            IpswCatalogCommand.self,
            IpswFetchCommand.self,
            IpswListCommand.self,
            IpswRmCommand.self,
        ]
    )
}

// MARK: - latest

struct IpswLatestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latest",
        abstract: "查询 Apple 当前推荐的最新 macOS guest IPSW (不下载)"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let entry = try await IPSWFetcher.resolveLatest()
            let cached = IPSWFetcher.isCached(buildVersion: entry.buildVersion)
            switch format {
            case .human:
                print("最新 macOS guest IPSW:")
                print("  build:       \(entry.buildVersion)")
                print("  os version:  \(entry.osVersion)")
                if let mc = entry.minCPU { print("  min cpu:     \(mc)") }
                if let mm = entry.minMemoryMiB { print("  min memory:  \(mm / 1024) GiB") }
                print("  url:         \(entry.url.absoluteString)")
                print("  cached:      \(cached ? "yes (\(IPSWFetcher.cachedPath(for: entry).path))" : "no")")
                if !cached {
                    print("\n下一步: hvm-cli ipsw fetch")
                }
            case .json:
                var payload = [
                    "buildVersion": entry.buildVersion,
                    "osVersion": entry.osVersion,
                    "url": entry.url.absoluteString,
                    "cached": cached ? "true" : "false",
                    "cachedPath": cached ? IPSWFetcher.cachedPath(for: entry).path : "",
                ]
                if let mc = entry.minCPU { payload["minCPU"] = "\(mc)" }
                if let mm = entry.minMemoryMiB { payload["minMemoryMiB"] = "\(mm)" }
                printJSON(payload)
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - catalog

struct IpswCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "列出 Apple catalog 里所有 VZ 可用的 macOS IPSW (从 mesu.apple.com)"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let entries = try await IPSWFetcher.fetchCatalog()
            switch format {
            case .human:
                if entries.isEmpty {
                    print("(catalog 里没有 VZ 可用的 IPSW — 可能 Apple 端点格式变了)")
                    return
                }
                print("OS_VERSION    BUILD       POSTED       CACHED  URL")
                for e in entries {
                    let osPad   = e.osVersion.padding(toLength: 13, withPad: " ", startingAt: 0)
                    let buildPad = e.buildVersion.padding(toLength: 11, withPad: " ", startingAt: 0)
                    let dateStr = e.postingDate.map { Self.dateFmt.string(from: $0) } ?? "—"
                    let datePad = dateStr.padding(toLength: 12, withPad: " ", startingAt: 0)
                    let cached  = IPSWFetcher.isCached(buildVersion: e.buildVersion) ? "yes   " : "no    "
                    print("\(osPad) \(buildPad) \(datePad) \(cached) \(e.url.absoluteString)")
                }
                print("")
                print("下一步: hvm-cli ipsw fetch --build <BUILD>")
            case .json:
                printJSON(entries.map { e -> [String: String] in
                    var d: [String: String] = [
                        "buildVersion": e.buildVersion,
                        "osVersion": e.osVersion,
                        "url": e.url.absoluteString,
                        "cached": IPSWFetcher.isCached(buildVersion: e.buildVersion) ? "true" : "false",
                    ]
                    if let pd = e.postingDate {
                        d["postingDate"] = ISO8601DateFormatter().string(from: pd)
                    }
                    return d
                })
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - fetch

struct IpswFetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "下载 macOS guest IPSW 到 cache (默认取 Apple 推荐最新; --build / --url 选指定版本)"
    )

    @Option(name: .long, help: "指定 buildVersion (如 24A335). 走 Apple catalog 解析. 与 --url 互斥")
    var build: String?

    @Option(name: .long, help: "指定 IPSW 远程 URL. 跳过 catalog, 直接拉. 与 --build 互斥")
    var url: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Flag(name: .long, help: "已缓存时也强制重新下载")
    var force: Bool = false

    @Flag(name: .long, help: "json 模式下流式输出每一帧 progress, 否则只在阶段切换时输出")
    var follow: Bool = false

    func run() async throws {
        do {
            // 三选一: --url > --build > 默认 latest
            if build != nil, url != nil {
                throw HVMError.config(.invalidEnum(field: "ipsw fetch", raw: "--build + --url 同时给", allowed: ["--build", "--url", "default(latest)"]))
            }

            let entry: IPSWCatalogEntry
            switch format {
            case .human:
                if let url { print("[resolving] 使用 --url: \(url)") }
                else if let build { print("[resolving] 解析 catalog 找 build=\(build)…") }
                else              { print("[resolving] 查询 Apple 推荐最新…") }
            case .json:  printJSON(["phase": "resolving"])
            }

            if let urlStr = url {
                guard let u = URL(string: urlStr) else {
                    throw HVMError.config(.invalidEnum(field: "ipsw fetch --url", raw: urlStr, allowed: ["http(s)://..."]))
                }
                entry = IPSWFetcher.resolveURL(u)
            } else if let build {
                entry = try await IPSWFetcher.resolveBuild(build)
            } else {
                entry = try await IPSWFetcher.resolveLatest()
            }

            // 续传提示: 有 .partial 时告诉用户从哪续 (好让用户感知)
            let resumeFrom = force ? 0 : IPSWFetcher.partialSize(buildVersion: entry.buildVersion)
            switch format {
            case .human:
                print("found: macOS \(entry.osVersion) (\(entry.buildVersion))")
                print("url:   \(entry.url.absoluteString)")
                if resumeFrom > 0 {
                    print("resume: \(Format.bytes(resumeFrom)) already on disk → 续传")
                }
            case .json:
                var payload = [
                    "phase": "resolved",
                    "buildVersion": entry.buildVersion,
                    "osVersion": entry.osVersion,
                    "url": entry.url.absoluteString,
                ]
                if resumeFrom > 0 {
                    payload["resumeFromBytes"] = "\(resumeFrom)"
                }
                printJSON(payload)
            }

            // 进度状态机. 节流由 IPSWFetcher 内部 (100ms) 已做; CLI 这层只做格式化.
            // tracker 持有上次 fraction, 用于 JSON 1% 步进过滤; 跨 URLSession queue 故 lock 保护.
            let formatBox = format
            let followBox = follow
            let tracker = ProgressTracker()

            let local = try await IPSWFetcher.downloadIfNeeded(
                entry: entry,
                force: force
            ) { p in
                Self.report(p, format: formatBox, follow: followBox, tracker: tracker)
            }

            switch format {
            case .human:
                print("")  // 收尾换行
                print("✔ 已就绪: \(local.path)")
                print("下一步: hvm-cli create --os macOS --ipsw \(local.path) ...")
            case .json:
                printJSON([
                    "phase": "succeeded",
                    "buildVersion": entry.buildVersion,
                    "path": local.path,
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    /// IPSWFetchProgress 翻成对外输出. human 走 \r 单行刷新百分比, json 一行一帧.
    /// 注意: onProgress 在 URLSession delegate queue 调用, 多线程并发, 但 print 本身线程安全.
    private static func report(_ p: IPSWFetchProgress, format: OutputFormat, follow: Bool, tracker: ProgressTracker) {
        switch p.phase {
        case .resolving:
            // 不会到这里 (resolveLatest 已分离)
            break
        case .alreadyCached:
            switch format {
            case .human:
                print("[cached] 缓存已命中, 跳过下载 (\(Format.bytes(p.receivedBytes)))")
            case .json:
                printJSON([
                    "phase": "alreadyCached",
                    "receivedBytes": "\(p.receivedBytes)",
                ])
            }
        case .downloading:
            let total = p.totalBytes ?? 0
            let f = total > 0 ? Double(p.receivedBytes) / Double(total) : 0
            switch format {
            case .human:
                let pct = total > 0 ? String(format: "%.1f%%", f * 100) : "?"
                let recv = Format.bytes(p.receivedBytes)
                let totalS = total > 0 ? Format.bytes(total) : "?"
                let rateS = p.bytesPerSecond.map { Format.rate($0, padded: true) } ?? "    --   "
                let etaS  = p.etaSeconds.map { Format.eta($0, padded: true) } ?? "  --  "
                // \r 单行刷新; 末尾留空格盖掉上一帧可能留下的字符
                print("\rdownloading: \(pct)  \(recv) / \(totalS)  \(rateS)  ETA \(etaS)   ", terminator: "")
                fflush(stdout)
            case .json:
                if follow || total <= 0 || tracker.shouldEmit(f, threshold: 0.01) {
                    var payload = [
                        "phase": "downloading",
                        "receivedBytes": "\(p.receivedBytes)",
                        "totalBytes": "\(total)",
                        "fraction": String(format: "%.4f", f),
                    ]
                    if let bps = p.bytesPerSecond {
                        payload["bytesPerSecond"] = String(format: "%.0f", bps)
                    }
                    if let eta = p.etaSeconds {
                        payload["etaSeconds"] = String(format: "%.0f", eta)
                    }
                    printJSON(payload)
                }
            }
        case .completed:
            switch format {
            case .human:
                let recv = Format.bytes(p.receivedBytes)
                print("\rdownloading: 100%  \(recv) / \(recv)        ")
                fflush(stdout)
            case .json:
                printJSON([
                    "phase": "downloaded",
                    "receivedBytes": "\(p.receivedBytes)",
                ])
            }
        }
    }
}

/// JSON 模式步进过滤器 (CLI 自用, 跨命令共享). onProgress 闭包跨线程, 用 NSLock 保护 lastFraction.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction: Double = -1

    func shouldEmit(_ f: Double, threshold: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if f - lastFraction >= threshold {
            lastFraction = f
            return true
        }
        return false
    }
}

// MARK: - list

struct IpswListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出已缓存的 IPSW"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        let items = IPSWFetcher.listCache()
        let partials = listPartials()
        switch format {
        case .human:
            if items.isEmpty && partials.isEmpty {
                print("(cache 为空: \(HVMPaths.ipswCacheDir.path))")
                return
            }
            if !items.isEmpty {
                print("BUILD       SIZE         PATH")
                for it in items {
                    let size = Format.bytes(it.sizeBytes).padding(toLength: 12, withPad: " ", startingAt: 0)
                    let build = it.buildVersion.padding(toLength: 11, withPad: " ", startingAt: 0)
                    print("\(build) \(size) \(it.path)")
                }
            }
            if !partials.isEmpty {
                if !items.isEmpty { print("") }
                print("半成品 (.partial, 续传中或被中断):")
                print("BUILD       SIZE         PATH")
                for (build, size, path) in partials {
                    let s = Format.bytes(size).padding(toLength: 12, withPad: " ", startingAt: 0)
                    let b = build.padding(toLength: 11, withPad: " ", startingAt: 0)
                    print("\(b) \(s) \(path)")
                }
            }
        case .json:
            // 把 partial 也进 JSON 一起输出, 方便脚本判断
            let partialPayload = partials.map { (build, size, path) -> [String: String] in
                ["buildVersion": build, "sizeBytes": "\(size)", "path": path, "partial": "true"]
            }
            let combined = items.map { it -> [String: String] in
                ["buildVersion": it.buildVersion, "sizeBytes": "\(it.sizeBytes)", "path": it.path, "partial": "false"]
            } + partialPayload
            printJSON(combined)
        }
    }

    /// 列 cache 目录下所有 .partial 文件 (下载中或被中断的半成品).
    private func listPartials() -> [(build: String, size: Int64, path: String)] {
        let dir = HVMPaths.ipswCacheDir
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> (String, Int64, String)? in
            // 命名规则 <build>.ipsw.partial
            guard url.pathExtension.lowercased() == "partial" else { return nil }
            let stem = url.deletingPathExtension()
            guard stem.pathExtension.lowercased() == "ipsw" else { return nil }
            let build = stem.deletingPathExtension().lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return (build, size, url.path)
        }
        .sorted { $0.0 < $1.0 }
    }
}

// MARK: - rm

struct IpswRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "删除指定 build 的缓存 IPSW; build='all' 清空整个 cache"
    )

    @Argument(help: "buildVersion (如 24A335) 或 'all'")
    var build: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            if build.lowercased() == "all" {
                let before = IPSWFetcher.listCache()
                try IPSWFetcher.clearAllCache()
                switch format {
                case .human: print("✔ 已清空 \(before.count) 个 IPSW 缓存")
                case .json:  printJSON(["ok": "true", "removed": "\(before.count)"])
                }
            } else {
                try IPSWFetcher.removeCache(buildVersion: build)
                switch format {
                case .human: print("✔ 已删除 cache: \(build)")
                case .json:  printJSON(["ok": "true", "buildVersion": build])
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
