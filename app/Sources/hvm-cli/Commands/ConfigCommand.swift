// ConfigCommand.swift
// hvm-cli config get / set — 读/改 VM 配置 (CPU / 内存).
// 必须 VM stopped (VZ 不支持热改 CPU/内存; 改完下次 start 时 ConfigBuilder 重新校验).

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "读/改 VM 配置 (cpu / memory)",
        subcommands: [ConfigGetCommand.self, ConfigSetCommand.self]
    )
}

struct ConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "打印当前 VM 配置"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let config = try BundleIO.load(from: bundleURL)
            switch format {
            case .json:
                printJSON([
                    "displayName": config.displayName,
                    "guestOS":     config.guestOS.rawValue,
                    "cpuCount":    String(config.cpuCount),
                    "memoryMiB":   String(config.memoryMiB),
                    "memoryGiB":   String(config.memoryMiB / 1024),
                ])
            case .human:
                print("displayName: \(config.displayName)")
                print("guestOS:     \(config.guestOS.rawValue)")
                print("cpu:         \(config.cpuCount)")
                print("memory:      \(config.memoryMiB / 1024) GiB (\(config.memoryMiB) MiB)")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "改 VM 配置. 必须 VM stopped"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "新 CPU 核数")
    var cpu: Int?

    @Option(name: .long, help: "新内存 (GiB)")
    var memory: UInt64?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            guard cpu != nil || memory != nil else {
                throw HVMError.config(.missingField(name: "config set 至少需要 --cpu 或 --memory 之一"))
            }
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            var config = try BundleIO.load(from: bundleURL)
            if let c = cpu {
                guard c >= 1 else {
                    throw HVMError.config(.missingField(name: "cpu 必须 >=1"))
                }
                config.cpuCount = c
            }
            if let m = memory {
                guard m >= 1 else {
                    throw HVMError.config(.missingField(name: "memory 必须 >=1 GiB"))
                }
                config.memoryMiB = m * 1024
            }
            // VZ 范围由 ConfigBuilder 在下次 start 时校验, 这里不强 import Virtualization
            try BundleIO.save(config: config, to: bundleURL)
            switch format {
            case .human:
                print("✔ 已更新 cpu=\(config.cpuCount) memory=\(config.memoryMiB / 1024)gb")
            case .json:
                printJSON([
                    "ok":        "true",
                    "cpuCount":  String(config.cpuCount),
                    "memoryMiB": String(config.memoryMiB),
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
