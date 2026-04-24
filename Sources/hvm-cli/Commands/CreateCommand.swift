// CreateCommand.swift
// hvm-cli create — 非交互式创建 Linux bundle (M1 只 Linux)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMNet
import HVMStorage

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "创建新 VM bundle"
    )

    @Option(name: .long, help: "VM 名称 (必填)")
    var name: String

    @Option(name: .long, help: "Guest OS: linux (M1 只支持 linux)")
    var os: String = "linux"

    @Option(name: .long, help: "CPU 核心数")
    var cpu: Int = 4

    @Option(name: .long, help: "内存 GiB")
    var memory: UInt64 = 4

    @Option(name: .long, help: "主盘大小 GiB")
    var disk: UInt64 = 64

    @Option(name: .long, help: "安装 ISO 绝对路径 (Linux 必填)")
    var iso: String?

    @Option(name: .long, help: "网络模式: nat | bridged:<iface>")
    var network: String = "nat"

    @Option(name: .long, help: "bundle 父目录, 默认 ~/Library/Application Support/HVM/VMs")
    var path: String?

    @Option(name: .long, help: "手动指定 MAC 地址 (默认随机 locally-administered)")
    var mac: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let os = try parseGuestOS(self.os)
            guard os == .linux else {
                throw HVMError.backend(.unsupportedGuestOS(raw: self.os + " (M1 只支持 linux)"))
            }

            guard let isoPath = iso else {
                throw HVMError.config(.missingField(name: "iso"))
            }
            try ISOValidator.validate(at: isoPath)

            let network = try parseNetwork(self.network)
            let macAddr = try resolveMAC(explicit: self.mac)

            let parentDir = URL(fileURLWithPath:
                self.path ?? HVMPaths.vmsRoot.path,
                isDirectory: true
            )
            try HVMPaths.ensure(parentDir)
            let bundleURL = parentDir.appendingPathComponent("\(name).hvmz", isDirectory: true)

            // 卷空间预检
            try VolumeInfo.assertSpaceAvailable(
                at: parentDir.path,
                requiredBytes: UInt64(disk) * (1 << 30)
            )

            let config = VMConfig(
                displayName: name,
                guestOS: os,
                cpuCount: cpu,
                memoryMiB: memory * 1024,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: disk)],
                networks: [NetworkSpec(mode: network, macAddress: macAddr)],
                installerISO: isoPath,
                bootFromDiskOnly: false,
                linux: LinuxSpec()
            )

            try BundleIO.create(at: bundleURL, config: config)
            try DiskFactory.create(
                at: BundleLayout.mainDiskURL(bundleURL),
                sizeGiB: disk
            )

            switch format {
            case .human:
                print("✔ 已创建 \(bundleURL.path)")
                print("  id:        \(config.id.uuidString)")
                print("  guestOS:   \(config.guestOS.rawValue)")
                print("  cpu/mem:   \(config.cpuCount) 核 / \(config.memoryMiB / 1024) GiB")
                print("  disk:      \(disk) GiB (raw sparse)")
                print("  iso:       \(isoPath)")
                print("  mac:       \(macAddr)")
                print("下一步: hvm-cli start \(name)")
            case .json:
                printJSON([
                    "bundlePath": bundleURL.path,
                    "id": config.id.uuidString,
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func parseGuestOS(_ raw: String) throws -> GuestOSType {
        if let v = GuestOSType(rawValue: raw) { return v }
        throw HVMError.config(.invalidEnum(
            field: "os", raw: raw,
            allowed: GuestOSType.allCases.map { $0.rawValue }
        ))
    }

    private func parseNetwork(_ raw: String) throws -> NetworkMode {
        if raw == "nat" { return .nat }
        if raw.hasPrefix("bridged:") {
            let iface = String(raw.dropFirst("bridged:".count))
            guard !iface.isEmpty else {
                throw HVMError.config(.invalidEnum(field: "network", raw: raw,
                                                   allowed: ["nat", "bridged:<iface>"]))
            }
            return .bridged(interface: iface)
        }
        throw HVMError.config(.invalidEnum(field: "network", raw: raw,
                                           allowed: ["nat", "bridged:<iface>"]))
    }

    private func resolveMAC(explicit: String?) throws -> String {
        if let m = explicit {
            try MACAddressGenerator.validate(m)
            return m
        }
        return MACAddressGenerator.random()
    }
}
