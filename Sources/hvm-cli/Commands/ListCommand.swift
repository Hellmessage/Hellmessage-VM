// ListCommand.swift
// hvm-cli list — 列出所有 VM

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMStorage

private func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
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
        let root = bundleDir.map { URL(fileURLWithPath: $0) } ?? HVMPaths.vmsRoot
        let bundles = (try? BundleDiscovery.list(in: root)) ?? []

        var rows: [Row] = []
        for b in bundles {
            let state = BundleLock.isBusy(bundleURL: b) ? "running" : "stopped"
            guard let config = try? BundleIO.load(from: b) else { continue }

            let mainURL = BundleLayout.mainDiskURL(b)
            let actualBytes = (try? DiskFactory.actualBytes(at: mainURL)) ?? 0
            let logicalBytes = (try? DiskFactory.logicalBytes(at: mainURL)) ?? 0

            rows.append(Row(
                name: b.deletingPathExtension().lastPathComponent,
                id: config.id.uuidString,
                guestOS: config.guestOS.rawValue,
                state: state,
                cpuCount: config.cpuCount,
                memoryMiB: config.memoryMiB,
                mainDiskActualGiB: Double(actualBytes) / Double(1 << 30),
                mainDiskLogicalGiB: logicalBytes / (1 << 30),
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
