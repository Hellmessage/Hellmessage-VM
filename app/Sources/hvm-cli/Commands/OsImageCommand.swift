// OsImageCommand.swift
// hvm-cli osimage — Linux / Windows guest ISO 镜像下载与缓存管理.
//
// 子命令:
//   list            列 OSImageCatalog 内置发行版 (id / version / cached?)
//   fetch <id>      下载内置 entry, SHA256 校验
//   fetch --url U   下载自定义 URL (无校验)
//   cache           列已缓存 (~/Library/Application Support/HVM/cache/os-images)
//   rm <id|all>     删缓存
//
// 详见 docs/GUEST_OS_INSTALL.md

import ArgumentParser
import Foundation
import HVMCore
import HVMInstall
import HVMUtils

struct OsImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osimage",
        abstract: "Linux / Windows guest ISO 自动下载与缓存管理 (~/Library/Application Support/HVM/cache/os-images)",
        subcommands: [
            OsImageListCommand.self,
            OsImageFetchCommand.self,
            OsImageCacheCommand.self,
            OsImageRmCommand.self,
        ]
    )
}

// MARK: - list

struct OsImageListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列 OSImageCatalog 内置 Linux 发行版 (含 id / version / 缓存状态)"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        let entries = OSImageCatalog.entries
        switch format {
        case .human:
            print("ID                       VERSION                        CACHED  SIZE      URL")
            for e in entries {
                let cached = OSImageFetcher.isCached(entry: e)
                let id = e.id.padding(toLength: 24, withPad: " ", startingAt: 0)
                let ver = e.version.padding(toLength: 30, withPad: " ", startingAt: 0)
                let cacheLabel = cached ? "yes   " : "no    "
                let size = e.approximateSize > 0 ? "~\(Format.bytes(e.approximateSize))" : "?"
                let sizePad = size.padding(toLength: 9, withPad: " ", startingAt: 0)
                print("\(id) \(ver) \(cacheLabel) \(sizePad) \(e.url.absoluteString)")
            }
            print("")
            print("下一步: hvm-cli osimage fetch <ID>")
        case .json:
            printJSON(entries.map { e -> [String: String] in
                [
                    "id": e.id,
                    "displayName": e.displayName,
                    "family": e.family.rawValue,
                    "version": e.version,
                    "url": e.url.absoluteString,
                    "sha256": e.sha256 ?? "",
                    "approximateSize": "\(e.approximateSize)",
                    "cached": OSImageFetcher.isCached(entry: e) ? "true" : "false",
                ]
            })
        }
    }
}

// MARK: - fetch

struct OsImageFetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "下载 catalog 内 entry (--url 自填 URL 跳过校验)"
    )

    @Argument(help: "catalog 内 entry id (e.g. ubuntu-24.04). 与 --url 互斥, 二选一")
    var id: String?

    @Option(name: .long, help: "自定义下载 URL (跳过 SHA 校验). 与 id 互斥")
    var url: String?

    @Flag(name: .long, help: "已缓存时也强制重下")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Flag(name: .long, help: "json 模式下流式输出每帧 progress")
    var follow: Bool = false

    func run() async throws {
        if id == nil && url == nil {
            throw HVMError.config(.invalidEnum(field: "osimage fetch", raw: "未指定", allowed: ["id (e.g. ubuntu-24.04)", "--url <URL>"]))
        }
        if id != nil && url != nil {
            throw HVMError.config(.invalidEnum(field: "osimage fetch", raw: "id + --url 同时给", allowed: ["id only", "--url only"]))
        }

        let tracker = ProgressTracker()
        do {
            let local: URL
            if let id {
                guard let entry = OSImageCatalog.find(id: id) else {
                    throw HVMError.config(.invalidEnum(
                        field: "osimage fetch id", raw: id,
                        allowed: OSImageCatalog.entries.map { $0.id }
                    ))
                }
                printResolved(entry: entry)
                local = try await OSImageFetcher.downloadIfNeeded(entry: entry, force: force) { p in
                    self.printProgress(p, tracker: tracker)
                }
            } else if let urlStr = url {
                guard let u = URL(string: urlStr) else {
                    throw HVMError.config(.invalidEnum(field: "osimage fetch --url", raw: urlStr, allowed: ["http(s)://..."]))
                }
                printResolvedCustom(url: u)
                local = try await OSImageFetcher.downloadCustom(url: u, force: force) { p in
                    self.printProgress(p, tracker: tracker)
                }
            } else {
                return
            }
            switch format {
            case .human:
                print("\nlocal: \(local.path)")
            case .json:
                printJSON(["phase": "ready", "path": local.path])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func printResolved(entry: OSImageEntry) {
        switch format {
        case .human:
            print("found: \(entry.displayName) (\(entry.version))")
            print("url:   \(entry.url.absoluteString)")
            if let sha = entry.sha256 {
                print("sha:   \(sha) (校验)")
            } else {
                print("sha:   - (rolling, 跳过校验)")
            }
        case .json:
            var d: [String: String] = [
                "phase": "resolved",
                "id": entry.id,
                "url": entry.url.absoluteString,
            ]
            if let sha = entry.sha256 { d["sha256"] = sha }
            printJSON(d)
        }
    }

    private func printResolvedCustom(url: URL) {
        switch format {
        case .human:
            print("custom URL: \(url.absoluteString)")
            print("sha:   - (custom, 跳过校验)")
        case .json:
            printJSON(["phase": "resolved", "url": url.absoluteString])
        }
    }

    private func printProgress(_ p: OSImageFetchProgress, tracker: ProgressTracker) {
        let total = p.totalBytes ?? 0
        let f = total > 0 ? Double(p.receivedBytes) / Double(total) : 0
        switch format {
        case .human:
            switch p.phase {
            case .alreadyCached:
                print("[cached] 缓存已命中, 跳过下载 (\(Format.bytes(p.receivedBytes)))")
            case .downloading:
                let pct = total > 0 ? String(format: "%.1f%%", f * 100) : "?"
                let recv = Format.bytes(p.receivedBytes)
                let totalS = total > 0 ? Format.bytes(total) : "?"
                let rateS = p.bytesPerSecond.map { Format.rate($0, padded: true) } ?? "    --   "
                let etaS  = p.etaSeconds.map { Format.eta($0, padded: true) } ?? "  --  "
                print("\rdownloading: \(pct)  \(recv) / \(totalS)  \(rateS)  ETA \(etaS)   ", terminator: "")
                fflush(stdout)
            case .verifying:
                print("\rverifying SHA256 of \(Format.bytes(p.receivedBytes))…                                ")
                fflush(stdout)
            case .completed:
                print("\rcompleted: 100%  \(Format.bytes(p.receivedBytes))                                  ")
                fflush(stdout)
            }
        case .json:
            switch p.phase {
            case .alreadyCached:
                printJSON(["phase": "alreadyCached", "receivedBytes": "\(p.receivedBytes)"])
            case .downloading:
                if follow || total <= 0 || tracker.shouldEmit(f, threshold: 0.01) {
                    var payload = [
                        "phase": "downloading",
                        "receivedBytes": "\(p.receivedBytes)",
                        "totalBytes": "\(total)",
                        "fraction": String(format: "%.4f", f),
                    ]
                    if let bps = p.bytesPerSecond { payload["bytesPerSecond"] = String(format: "%.0f", bps) }
                    if let eta = p.etaSeconds { payload["etaSeconds"] = String(format: "%.0f", eta) }
                    printJSON(payload)
                }
            case .verifying:
                printJSON(["phase": "verifying", "receivedBytes": "\(p.receivedBytes)"])
            case .completed:
                printJSON(["phase": "completed", "receivedBytes": "\(p.receivedBytes)"])
            }
        }
    }
}

// MARK: - cache

struct OsImageCacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "列已缓存的 OS image"
    )

    @Option(name: .long, help: "只列指定 family (ubuntu/debian/fedora/alpine/rocky/opensuse/custom)")
    var family: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        let famFilter: OSImageFamily? = family.flatMap { OSImageFamily(rawValue: $0) }
        let items = OSImageFetcher.listCache(family: famFilter)
        switch format {
        case .human:
            if items.isEmpty {
                print("(cache 空)")
                return
            }
            print("FAMILY     ENTRY-ID                 SIZE       PATH")
            for it in items {
                let fam = it.family.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                let eid = (it.entryId ?? "-").padding(toLength: 24, withPad: " ", startingAt: 0)
                let size = Format.bytes(it.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)
                print("\(fam) \(eid) \(size) \(it.path)")
            }
        case .json:
            printJSON(items.map { it -> [String: String] in
                [
                    "family": it.family.rawValue,
                    "entryId": it.entryId ?? "",
                    "path": it.path,
                    "sizeBytes": "\(it.sizeBytes)",
                ]
            })
        }
    }
}

// MARK: - rm

struct OsImageRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "删除单个 entry 缓存 (含 .partial / .meta) 或 all 全部"
    )

    @Argument(help: "catalog entry id (e.g. ubuntu-24.04) 或 all")
    var target: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            if target == "all" {
                let items = OSImageFetcher.listCache()
                for it in items {
                    if let id = it.entryId, let entry = OSImageCatalog.find(id: id) {
                        try OSImageFetcher.removeCache(entry: entry)
                    } else {
                        // custom 下载 / 没在 catalog 的, 直接 ResumableDownloader.clearAll
                        let url = URL(fileURLWithPath: it.path)
                        try ResumableDownloader.clearAll(at: url)
                    }
                }
                switch format {
                case .human: print("删除完成: \(items.count) 项")
                case .json:  printJSON(["removed": "\(items.count)"])
                }
            } else {
                guard let entry = OSImageCatalog.find(id: target) else {
                    throw HVMError.config(.invalidEnum(
                        field: "osimage rm target", raw: target,
                        allowed: OSImageCatalog.entries.map { $0.id } + ["all"]
                    ))
                }
                try OSImageFetcher.removeCache(entry: entry)
                switch format {
                case .human: print("删除: \(entry.id)")
                case .json:  printJSON(["removed": entry.id])
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
