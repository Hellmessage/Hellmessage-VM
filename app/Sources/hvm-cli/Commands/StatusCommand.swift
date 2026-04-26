// StatusCommand.swift
// hvm-cli status — 显示单 VM 详情 (含运行时 IPC 信息, 如果在跑)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC
import HVMStorage

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "显示单个 VM 详情"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let config = try BundleIO.load(from: bundleURL)

            let busy = BundleLock.isBusy(bundleURL: bundleURL)
            var runtimePayload: IPCStatusPayload?

            if busy, let holder = BundleLock.inspect(bundleURL: bundleURL),
               !holder.socketPath.isEmpty {
                let req = IPCRequest(op: IPCOp.status.rawValue)
                if let resp = try? SocketClient.request(socketPath: holder.socketPath, request: req),
                   resp.ok,
                   let jsonStr = resp.data?["payload"],
                   let jsonData = jsonStr.data(using: .utf8) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    runtimePayload = try? decoder.decode(IPCStatusPayload.self, from: jsonData)
                }
            }

            let mainURL = BundleLayout.mainDiskURL(bundleURL)
            let actualBytes = (try? DiskFactory.actualBytes(at: mainURL)) ?? 0
            let logicalBytes = (try? DiskFactory.logicalBytes(at: mainURL)) ?? 0

            switch format {
            case .json:
                let obj: [String: Any] = [
                    "name": bundleURL.deletingPathExtension().lastPathComponent,
                    "id": config.id.uuidString,
                    "guestOS": config.guestOS.rawValue,
                    "state": runtimePayload?.state ?? (busy ? "running" : "stopped"),
                    "cpuCount": config.cpuCount,
                    "memoryMiB": config.memoryMiB,
                    "bundlePath": bundleURL.path,
                    "mainDisk": [
                        "actualBytes": actualBytes,
                        "logicalBytes": logicalBytes,
                    ],
                    "pid": runtimePayload?.pid as Any,
                    "startedAt": runtimePayload?.startedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
                   let s = String(data: data, encoding: .utf8) {
                    print(s)
                }

            case .human:
                print("\(bundleURL.deletingPathExtension().lastPathComponent) (\(config.guestOS.rawValue))")
                print("  id:         \(config.id.uuidString)")
                print("  state:      \(runtimePayload?.state ?? (busy ? "running" : "stopped"))")
                if let pid = runtimePayload?.pid {
                    print("  host pid:   \(pid)")
                }
                print("  cpu:        \(config.cpuCount) 核")
                print("  memory:     \(config.memoryMiB / 1024) GiB")
                print("  disk main:  \(String(format: "%.1f", Double(actualBytes) / Double(1 << 30))) GiB 已占用 / \(logicalBytes / (1 << 30)) GiB")
                if let iso = config.installerISO {
                    print("  iso:        \(iso)")
                }
                print("  bootFromDiskOnly: \(config.bootFromDiskOnly)")
                if let net = config.networks.first {
                    let modeStr: String
                    switch net.mode {
                    case .nat: modeStr = "nat"
                    case .bridged(let i): modeStr = "bridged(\(i))"
                    case .shared: modeStr = "shared"
                    }
                    print("  network:    \(modeStr) · \(net.macAddress)")
                }
                print("  bundle:     \(bundleURL.path)")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
