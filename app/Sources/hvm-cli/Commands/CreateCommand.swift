// CreateCommand.swift
// hvm-cli create — 非交互式创建 VM bundle (Linux / Windows arm64 ISO 装机)

import ArgumentParser
import Foundation
import HVMBundle
import HVMControl
import HVMCore
import HVMNet
import HVMQemu
import HVMStorage

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "创建新 VM bundle"
    )

    @Option(name: .long, help: "VM 名称 (必填)")
    var name: String

    @Option(name: .long, help: "Guest OS: linux | windows (macOS 已下线 — VZ 后端移除)")
    var os: String = "linux"

    @Option(name: .long, help: "后端引擎: qemu (VZ 已下线; 此项保留仅为兼容, 恒 qemu)")
    var engine: Engine?

    @Option(name: .long, help: "CPU 核心数")
    var cpu: Int = 4

    @Option(name: .long, help: "内存 GiB")
    var memory: UInt64 = 4

    @Option(name: .long, help: "主盘大小 GiB")
    var disk: UInt64 = 64

    @Option(name: .long, help: "Linux 装机 ISO 绝对路径 (--os linux 必填)")
    var iso: String?

    @Option(name: .long, help: "(已下线 — macOS guest 随 VZ 移除; 保留仅为报错提示)")
    var ipsw: String?

    @Option(name: .customLong("import-disk"),
            help: "导入现成 qcow2 / raw 镜像作为主盘 (例 OpenWrt). 与 --iso / --ipsw 互斥, 仅 --os linux 支持")
    var importDisk: String?

    @Option(name: .long, help: "网络模式: nat | bridged:<iface>")
    var network: String = "nat"

    @Option(name: .long, help: "bundle 父目录, 默认 ~/Library/Application Support/HVM/VMs")
    var path: String?

    @Option(name: .long, help: "手动指定 MAC 地址 (默认随机 locally-administered)")
    var mac: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Flag(name: .long, help: "创建加密 VM (强制 engine=qemu, prompt 密码; 跨机器 portable)")
    var encrypt: Bool = false

    func run() async throws {
        do {
            let os = try parseGuestOS(self.os)

            // ---- 导入磁盘镜像分支 (跳过 ISO 装机, 直接 boot; 仅 CLI, GUI 不接) ----
            if let importPath = importDisk {
                try runImport(os: os, importPath: importPath)
                return
            }

            // ---- ISO 装机 / 加密分支 → VMControl.create (CLI + GUI 单一来源) ----
            guard let isoPath = iso else { throw HVMError.config(.missingField(name: "iso")) }
            if ipsw != nil {
                throw HVMError.config(.invalidEnum(field: "ipsw", raw: "(set)",
                                                   allowed: ["(已下线 — macOS guest 随 VZ 移除)"]))
            }
            let (networkMode, networkIface) = try parseNetwork(self.network)
            let macAddr = try resolveMAC(explicit: self.mac)

            var password: String? = nil
            if encrypt {
                password = try PasswordPrompt.read(
                    prompt: "为加密 VM \(name) 设置密码: ",
                    confirm: true,
                    minLength: 4
                )
            }

            let spec = VMControl.CreateSpec(
                name: name,
                guestOS: os,
                cpuCount: cpu,
                memoryGiB: memory,
                diskGiB: disk,
                networkMode: networkMode,
                bridgedInterface: networkIface,
                macAddress: macAddr,
                installerISO: isoPath,
                parentDir: path.map { URL(fileURLWithPath: $0, isDirectory: true) },
                windows: os == .windows ? WindowsSpec() : nil,
                encrypt: encrypt,
                password: password
            )
            let result = try VMControl.create(spec)
            printCreated(bundleURL: result.bundleURL, config: result.config,
                         effectiveDiskGiB: disk, isoPath: isoPath, macAddr: macAddr,
                         imported: nil)
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    /// 导入现成 qcow2 / raw 镜像作主盘 (跳过装机, 直接 boot). 与 --iso / --ipsw / --encrypt 互斥, 仅 --os linux.
    private func runImport(os: GuestOSType, importPath: String) throws {
        guard os == .linux else {
            throw HVMError.config(.invalidEnum(field: "import-disk", raw: importPath,
                                               allowed: ["仅 --os linux 支持"]))
        }
        if iso != nil || ipsw != nil {
            throw HVMError.config(.invalidEnum(field: "import-disk", raw: importPath,
                                               allowed: ["与 --iso / --ipsw 互斥"]))
        }
        if encrypt {
            throw HVMError.config(.invalidEnum(field: "encrypt", raw: "import-disk",
                                               allowed: ["加密 VM 暂不支持 --import-disk (导入明文 qcow2 转 LUKS 留 PR-10)"]))
        }
        let qemuImgURL = try QemuPaths.qemuImgBinary()
        let importInfo = try DiskFactory.inspectImage(
            at: URL(fileURLWithPath: importPath),
            qemuImg: qemuImgURL
        )
        let (networkMode, networkIface) = try parseNetwork(self.network)
        let macAddr = try resolveMAC(explicit: self.mac)

        let parentDir = URL(fileURLWithPath: self.path ?? HVMPaths.vmsRoot.path, isDirectory: true)
        try HVMPaths.ensure(parentDir)
        let bundleURL = parentDir.appendingPathComponent("\(name).hvmz", isDirectory: true)

        // 预检值取 max(--disk, 镜像 virtual-size GiB)
        let effectiveDiskGiB = max(disk, importInfo.virtualSizeGiB)
        try VolumeInfo.assertSpaceAvailable(at: parentDir.path,
                                            requiredBytes: effectiveDiskGiB * (1 << 30))

        let mainFormat: DiskFormat = .qcow2
        let mainDiskFile = "\(BundleLayout.disksDirName)/\(BundleLayout.mainDiskFileName(for: .qemu))"
        let mainDisk = DiskSpec(role: .main, path: mainDiskFile,
                                sizeGiB: effectiveDiskGiB, format: mainFormat)
        let config = VMConfig(
            displayName: name,
            guestOS: os,
            engine: .qemu,
            cpuCount: cpu,
            memoryMiB: memory * 1024,
            disks: [mainDisk],
            networks: [NetworkSpec(mode: networkMode, macAddress: macAddr,
                                   bridgedInterface: networkIface)],
            installerISO: nil,
            bootFromDiskOnly: true,
            linux: LinuxSpec(),
            windows: nil
        )
        try BundleIO.create(at: bundleURL, config: config)
        let mainDiskAbs = bundleURL.appendingPathComponent(mainDiskFile)
        do {
            try DiskFactory.importImage(
                from: URL(fileURLWithPath: importPath),
                to: mainDiskAbs,
                info: importInfo,
                targetSizeGiB: effectiveDiskGiB,
                qemuImg: qemuImgURL
            )
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
        printCreated(bundleURL: bundleURL, config: config,
                     effectiveDiskGiB: effectiveDiskGiB, isoPath: nil, macAddr: macAddr,
                     imported: (path: importPath, info: importInfo))
    }

    /// 统一打印创建结果 (human / json). imported 非 nil 时打导入信息 + 直接 boot 提示.
    private func printCreated(bundleURL: URL,
                              config: VMConfig,
                              effectiveDiskGiB: UInt64,
                              isoPath: String?,
                              macAddr: String,
                              imported: (path: String, info: DiskFactory.ImportableDiskInfo)?) {
        switch format {
        case .human:
            print("✔ 已创建 \(bundleURL.path)")
            print("  id:        \(config.id.uuidString)")
            print("  guestOS:   \(config.guestOS.rawValue)")
            print("  engine:    \(config.engine.rawValue)")
            print("  cpu/mem:   \(config.cpuCount) 核 / \(config.memoryMiB / 1024) GiB")
            print("  disk:      \(effectiveDiskGiB) GiB (qcow2)")
            if let p = isoPath { print("  iso:       \(p)") }
            if let im = imported {
                print("  imported:  \(im.path) (\(im.info.format.rawValue), 虚拟容量 \(im.info.virtualSizeGiB) GiB)")
            }
            print("  mac:       \(macAddr)")
            if imported != nil {
                print("下一步: hvm-cli start \(name)  (导入磁盘已就绪, 直接 boot)")
            } else {
                print("下一步: hvm-cli start \(name)  (在 guest 内完成安装, 然后 hvm-cli boot-from-disk \(name))")
            }
        case .json:
            printJSON([
                "bundlePath": bundleURL.path,
                "id": config.id.uuidString,
                "guestOS": config.guestOS.rawValue,
            ])
        }
    }

    private func parseGuestOS(_ raw: String) throws -> GuestOSType {
        if let v = GuestOSType(rawValue: raw) { return v }
        throw HVMError.config(.invalidEnum(
            field: "os", raw: raw,
            allowed: GuestOSType.allCases.map { $0.rawValue }
        ))
    }

    /// 解析 --network → (mode, bridgedInterface): nat→user, shared/host/none, bridged:<iface>.
    private func parseNetwork(_ raw: String) throws -> (NetworkMode, String?) {
        if raw == "nat" || raw == "user" { return (.user, nil) }
        if raw == "shared" { return (.vmnetShared, nil) }
        if raw == "host"   { return (.vmnetHost, nil) }
        if raw == "none"   { return (.none, nil) }
        if raw.hasPrefix("bridged:") {
            let iface = String(raw.dropFirst("bridged:".count))
            guard !iface.isEmpty else {
                throw HVMError.config(.invalidEnum(field: "network", raw: raw,
                                                   allowed: ["nat", "shared", "host", "bridged:<iface>", "none"]))
            }
            return (.vmnetBridged, iface)
        }
        throw HVMError.config(.invalidEnum(field: "network", raw: raw,
                                           allowed: ["nat", "shared", "host", "bridged:<iface>", "none"]))
    }

    private func resolveMAC(explicit: String?) throws -> String {
        if let m = explicit {
            try MACAddressGenerator.validate(m)
            return m
        }
        return MACAddressGenerator.random()
    }
}
