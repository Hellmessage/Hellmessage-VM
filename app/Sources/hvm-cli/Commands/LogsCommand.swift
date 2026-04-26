// LogsCommand.swift
// hvm-cli logs — 打印 VM 当天的 host 日志 (非 guest serial console; serial 在 M5 hvm-dbg console 里做)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "打印 VM 的 host 端日志"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "日期 yyyy-MM-dd, 默认今天")
    var date: String?

    @Flag(name: .long, help: "打印所有 log 文件 (谨慎, 可能很大)")
    var all: Bool = false

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let logsDir = bundleURL.appendingPathComponent("logs", isDirectory: true)
            guard FileManager.default.fileExists(atPath: logsDir.path) else {
                print("(无日志)")
                return
            }

            let files: [URL]
            if all {
                files = (try? FileManager.default.contentsOfDirectory(
                    at: logsDir, includingPropertiesForKeys: nil
                )) ?? []
            } else {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let dateStr = date ?? df.string(from: Date())
                let candidate = logsDir.appendingPathComponent("host-\(dateStr).log")
                files = FileManager.default.fileExists(atPath: candidate.path) ? [candidate] : []
            }

            for f in files {
                print("--- \(f.lastPathComponent) ---")
                if let data = try? Data(contentsOf: f), let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
            }
            if files.isEmpty { print("(无匹配日志)") }
        } catch {
            bail(error)
        }
    }
}
