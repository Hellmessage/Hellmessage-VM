// ListCommand.swift
// hvm-cli list — 列出所有 VM
// --watch / -w 持续刷新; Ctrl+C 退出.

import ArgumentParser
import Dispatch
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMStorage

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

/// SIGINT flag 跨线程传递盒. DispatchSource 在 .global() queue 上 set, 主 async 循环读.
private final class StopBox: @unchecked Sendable {
    private var v = false
    private let lock = NSLock()
    func set() { lock.lock(); v = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有 VM"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Option(name: .long, help: "bundle 搜索目录, 默认 ~/Library/Application Support/HVM/VMs")
    var bundleDir: String?

    @Flag(name: [.customShort("w"), .long], help: "持续刷新, Ctrl+C 退出")
    var watch: Bool = false

    @Option(name: .long, help: "watch 间隔秒数, 默认 2")
    var interval: Int = 2

    struct Row: Encodable, Sendable {
        let name: String
        let id: String
        let guestOS: String
        let state: String
        let cpuCount: Int
        let memoryMiB: UInt64
        let mainDiskActualGiB: Double
        let mainDiskLogicalGiB: UInt64
        let bundlePath: String
    }

    func run() async throws {
        if !watch {
            renderOnce()
            return
        }

        // watch 模式: 拦截 SIGINT, 循环刷新.
        // signal(SIGINT, SIG_IGN) 阻止默认终止, DispatchSource 把信号转成 handler 调用.
        // 100ms 切片轮询 stop flag, Ctrl+C 后最多 100ms 退出.
        guard interval > 0 else {
            FileHandle.standardError.write(Data("--interval 必须 > 0\n".utf8))
            throw ExitCode(2)
        }
        let stopBox = StopBox()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { stopBox.set() }
        src.resume()
        defer {
            src.cancel()
            signal(SIGINT, SIG_DFL)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        while !stopBox.get() {
            if format == .human {
                // ANSI: 光标回 (1,1) + 清屏. 不在 json 模式做, 方便 pipe 给 jq.
                print("\u{1B}[H\u{1B}[2J", terminator: "")
                print("[\(df.string(from: Date()))] hvm-cli list --watch (interval=\(interval)s, Ctrl+C to exit)")
            }
            renderOnce()

            let slices = interval * 10
            for _ in 0..<slices {
                if stopBox.get() { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// 单次扫 + 渲染. run() 直接调一次, watch 循环每 interval 调一次.
    private func renderOnce() {
        let root = bundleDir.map { URL(fileURLWithPath: $0) } ?? HVMPaths.vmsRoot
        let bundles = (try? BundleDiscovery.list(in: root)) ?? []

        var rows: [Row] = []
        for b in bundles {
            let state = BundleLock.isBusy(bundleURL: b) ? "running" : "stopped"
            // 加密 VM 没有明文 config.yaml, BundleIO.load 会抛 .notFound. 走 routing JSON
            // 拿基础信息 (displayName / vmId / scheme); cpu/mem/disk 不解密读不到, 用 0 占位.
            if EncryptedBundleIO.detectScheme(at: b) != nil {
                let routingURL = RoutingJSON.locationForQemuBundle(b)
                if let routing = try? RoutingJSON.read(from: routingURL) {
                    rows.append(Row(
                        name: b.deletingPathExtension().lastPathComponent,
                        id: routing.vmId.uuidString,
                        guestOS: "encrypted",
                        state: state,
                        cpuCount: 0,
                        memoryMiB: 0,
                        mainDiskActualGiB: 0,
                        mainDiskLogicalGiB: 0,
                        bundlePath: b.path
                    ))
                }
                continue
            }
            guard let config = try? BundleIO.load(from: b) else { continue }

            // 主盘路径走 config.disks (engine-aware), 不再用 BundleLayout 常量推断
            let mainURL = config.mainDiskURL(in: b) ?? b
            let actualBytes = (try? DiskFactory.actualBytes(at: mainURL)) ?? 0
            // qcow2 的 stat.st_size = 文件实际字节 (刚创 ~200KB), 不是 guest 看到的 virtual size,
            // 直接当 logical 用会显示成 0Gi. 用 DiskSpec.sizeGiB (config 里的名义容量) 兜底.
            // raw sparse: logicalBytes 等于 ftruncate 撑出来的名义大小, 也跟 sizeGiB 对齐, 仍可一致使用.
            let logicalGiB = UInt64(config.disks.first?.sizeGiB ?? 0)

            rows.append(Row(
                name: b.deletingPathExtension().lastPathComponent,
                id: config.id.uuidString,
                guestOS: config.guestOS.rawValue,
                state: state,
                cpuCount: config.cpuCount,
                memoryMiB: config.memoryMiB,
                mainDiskActualGiB: Double(actualBytes) / Double(1 << 30),
                mainDiskLogicalGiB: logicalGiB,
                bundlePath: b.path
            ))
        }

        switch format {
        case .json:
            printJSON(rows)
        case .human:
            if rows.isEmpty {
                print("(无 VM)")
                return
            }
            let nameW = max(4, rows.map { $0.name.count }.max() ?? 4)
            let osW = 6
            let stateW = 8
            print("\(pad("NAME", nameW))  \(pad("GUEST", osW))  \(pad("STATE", stateW))  CPU  MEM    DISK(main)")
            for r in rows {
                let diskStr = String(format: "%.1f/%dGi", r.mainDiskActualGiB, r.mainDiskLogicalGiB)
                let memStr  = "\(r.memoryMiB / 1024)Gi"
                print("\(pad(r.name, nameW))  \(pad(r.guestOS, osW))  \(pad(r.state, stateW))  \(pad("\(r.cpuCount)", 3))  \(pad(memStr, 5))  \(diskStr)")
            }
        }
    }
}
