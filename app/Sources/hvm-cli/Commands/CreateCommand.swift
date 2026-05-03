// CreateCommand.swift
// hvm-cli create — 非交互式创建 VM bundle (Linux ISO 引导 / macOS IPSW 装机)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
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

    @Option(name: .long, help: "Guest OS: linux | macOS | windows")
    var os: String = "linux"

    @Option(name: .long, help: "后端引擎: vz | qemu (默认按 guestOS: linux/macOS=vz, windows=qemu)")
    var engine: Engine?

    @Option(name: .long, help: "CPU 核心数")
    var cpu: Int = 4

    @Option(name: .long, help: "内存 GiB")
    var memory: UInt64 = 4

    @Option(name: .long, help: "主盘大小 GiB")
    var disk: UInt64 = 64

    @Option(name: .long, help: "Linux 装机 ISO 绝对路径 (--os linux 必填)")
    var iso: String?

    @Option(name: .long, help: "macOS 装机 IPSW 绝对路径 (--os macOS 必填)")
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

            // ---- 导入磁盘镜像分支 (跳过 ISO 装机, 直接 boot) ----
            // 与 --iso / --ipsw 互斥, 仅 --os linux 支持; engine 由镜像格式锁定 (qcow2→qemu, raw→vz)
            var importInfo: DiskFactory.ImportableDiskInfo? = nil
            if let importPath = importDisk {
                guard os == .linux else {
                    throw HVMError.config(.invalidEnum(field: "import-disk", raw: importPath,
                                                       allowed: ["仅 --os linux 支持"]))
                }
                if iso != nil || ipsw != nil {
                    throw HVMError.config(.invalidEnum(field: "import-disk", raw: importPath,
                                                       allowed: ["与 --iso / --ipsw 互斥"]))
                }
                let qemuImgURL = try QemuPaths.qemuImgBinary()
                importInfo = try DiskFactory.inspectImage(
                    at: URL(fileURLWithPath: importPath),
                    qemuImg: qemuImgURL
                )
            }

            // engine: 导入时由镜像格式锁定; 否则按 --engine / guestOS 默认.
            // ArgumentParser 已在解析阶段把非 vz/qemu 的拼写错挡掉, self.engine 只可能是
            // .vz / .qemu / nil, 这里不再校验字符串.
            let engineValue: Engine
            if let info = importInfo {
                let inferred: Engine = info.format == .qcow2 ? .qemu : .vz
                if let user = self.engine, user != inferred {
                    throw HVMError.config(.invalidEnum(field: "engine", raw: user.rawValue,
                                                       allowed: ["导入 \(info.format.rawValue) 镜像时 engine 锁定为 \(inferred.rawValue)"]))
                }
                engineValue = inferred
            } else {
                engineValue = resolveEngine(explicit: self.engine, guestOS: os)
            }

            // OS 分支专属字段校验 (导入分支已在上面处理, 此处只走 ISO/IPSW)
            var isoPath: String? = nil
            var ipswPath: String? = nil
            if importInfo == nil {
                switch os {
                case .linux, .windows:
                    guard let p = iso else { throw HVMError.config(.missingField(name: "iso")) }
                    try ISOValidator.validate(at: p)
                    isoPath = p
                    if ipsw != nil {
                        throw HVMError.config(.invalidEnum(field: "ipsw", raw: "(set)",
                                                           allowed: ["仅 --os macOS 时使用"]))
                    }
                case .macOS:
                    guard let p = ipsw else { throw HVMError.config(.missingField(name: "ipsw")) }
                    guard FileManager.default.fileExists(atPath: p) else {
                        throw HVMError.install(.ipswNotFound(path: p))
                    }
                    ipswPath = p
                    if iso != nil {
                        throw HVMError.config(.invalidEnum(field: "iso", raw: "(set)",
                                                           allowed: ["仅 --os linux 时使用"]))
                    }
                }
            }

            let (networkMode, networkIface) = try parseNetwork(self.network)
            let macAddr = try resolveMAC(explicit: self.mac)

            let parentDir = URL(fileURLWithPath:
                self.path ?? HVMPaths.vmsRoot.path,
                isDirectory: true
            )
            try HVMPaths.ensure(parentDir)
            let bundleURL = parentDir.appendingPathComponent("\(name).hvmz", isDirectory: true)

            // 卷空间预检 (主盘. macOS 装机时 IPSW 缓冲单独在 install 阶段预检)
            // 导入模式: 用 max(--disk, 镜像 virtual-size GiB) 作为预检值, 防呆下限就是镜像本身
            let effectiveDiskGiB: UInt64 = {
                if let info = importInfo { return max(disk, info.virtualSizeGiB) }
                return disk
            }()
            try VolumeInfo.assertSpaceAvailable(
                at: parentDir.path,
                requiredBytes: effectiveDiskGiB * (1 << 30)
            )

            // engine-aware 主盘: VZ → os.img (raw), QEMU → os.qcow2
            let mainFormat: DiskFormat = engineValue == .qemu ? .qcow2 : .raw
            let mainDiskFile = "\(BundleLayout.disksDirName)/\(BundleLayout.mainDiskFileName(for: engineValue))"
            let mainDisk = DiskSpec(
                role: .main,
                path: mainDiskFile,
                sizeGiB: effectiveDiskGiB,
                format: mainFormat
            )
            let config = VMConfig(
                displayName: name,
                guestOS: os,
                engine: engineValue,
                cpuCount: cpu,
                memoryMiB: memory * 1024,
                disks: [mainDisk],
                networks: [NetworkSpec(
                    mode: networkMode,
                    macAddress: macAddr,
                    bridgedInterface: networkIface
                )],
                installerISO: isoPath,
                bootFromDiskOnly: importInfo != nil,
                macOS: os == .macOS ? MacOSSpec(ipsw: ipswPath, autoInstalled: false) : nil,
                linux: os == .linux ? LinuxSpec() : nil,
                windows: os == .windows ? WindowsSpec() : nil
            )

            // ---- 加密分支 (--encrypt; v2.4 仅 QEMU) ----
            if encrypt {
                guard engineValue == .qemu else {
                    throw HVMError.config(.invalidEnum(
                        field: "encrypt",
                        raw: "engine=\(engineValue.rawValue)",
                        allowed: ["仅 QEMU 后端支持加密 (--engine qemu); macOS guest 必走 VZ 无法加密 (v2.4 决策)"]
                    ))
                }
                guard importInfo == nil else {
                    throw HVMError.config(.invalidEnum(
                        field: "encrypt",
                        raw: "import-disk",
                        allowed: ["加密 VM 暂不支持 --import-disk (导入明文 qcow2 转 LUKS 留 PR-10)"]
                    ))
                }
                let password = try PasswordPrompt.read(
                    prompt: "为加密 VM \(name) 设置密码: ",
                    confirm: true,
                    minLength: 4
                )
                try createEncryptedVM(
                    parentDir: parentDir,
                    bundleURL: bundleURL,
                    password: password,
                    config: config,
                    sizeGiB: effectiveDiskGiB
                )
            } else {
                try BundleIO.create(at: bundleURL, config: config)
                let qemuImg = mainFormat == .qcow2 ? (try? QemuPaths.qemuImgBinary()) : nil
                let mainDiskAbs = bundleURL.appendingPathComponent(mainDiskFile)
                if let info = importInfo, let importPath = importDisk {
                    do {
                        try DiskFactory.importImage(
                            from: URL(fileURLWithPath: importPath),
                            to: mainDiskAbs,
                            info: info,
                            targetSizeGiB: effectiveDiskGiB,
                            qemuImg: qemuImg
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: bundleURL)
                        throw error
                    }
                } else {
                    try DiskFactory.create(
                        at: mainDiskAbs,
                        sizeGiB: effectiveDiskGiB,
                        format: mainFormat,
                        qemuImg: qemuImg
                    )
                }
            }

            switch format {
            case .human:
                print("✔ 已创建 \(bundleURL.path)")
                print("  id:        \(config.id.uuidString)")
                print("  guestOS:   \(config.guestOS.rawValue)")
                print("  engine:    \(config.engine.rawValue)")
                print("  cpu/mem:   \(config.cpuCount) 核 / \(config.memoryMiB / 1024) GiB")
                print("  disk:      \(effectiveDiskGiB) GiB (\(mainFormat.rawValue))")
                if let p = isoPath  { print("  iso:       \(p)") }
                if let p = ipswPath { print("  ipsw:      \(p)") }
                if let p = importDisk, let info = importInfo {
                    print("  imported:  \(p) (\(info.format.rawValue), 虚拟容量 \(info.virtualSizeGiB) GiB)")
                }
                print("  mac:       \(macAddr)")
                if importInfo != nil {
                    print("下一步: hvm-cli start \(name)  (导入磁盘已就绪, 直接 boot)")
                } else {
                    switch os {
                    case .linux, .windows:
                        print("下一步: hvm-cli start \(name)  (在 guest 内完成安装, 然后 hvm-cli boot-from-disk \(name))")
                    case .macOS:
                        print("下一步: hvm-cli install \(name)  (跑 VZMacOSInstaller, 完成后直接 start)")
                    }
                }
            case .json:
                printJSON([
                    "bundlePath": bundleURL.path,
                    "id": config.id.uuidString,
                    "guestOS": config.guestOS.rawValue,
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

    /// 显式 --engine > 按 guestOS 默认 (linux/macOS=vz, windows=qemu).
    /// ArgumentParser 已在解析阶段校验 vz/qemu 拼写, explicit 已是 Engine? 不再需要 throw.
    /// 最终结果由 VMConfig.validate() 在 BundleIO.create 入口处再校验一次.
    private func resolveEngine(explicit: Engine?, guestOS: GuestOSType) -> Engine {
        if let v = explicit { return v }
        switch guestOS {
        case .linux, .macOS: return .vz
        case .windows:       return .qemu
        }
    }

    /// 创建加密 QEMU VM. 走 EncryptedBundleIO.create + QcowLuksFactory + OVMFVarsLuksFactory.
    /// 失败一律清残留 (handle.deinit 兜底 close).
    private func createEncryptedVM(parentDir: URL,
                                    bundleURL: URL,
                                    password: String,
                                    config: VMConfig,
                                    sizeGiB: UInt64) throws {
        // 1. EncryptedBundleIO.create 创建加密外壳 (config.yaml.enc + meta/encryption.json)
        let handle = try EncryptedBundleIO.create(
            parentDir: parentDir,
            displayName: config.displayName,
            password: password,
            baseConfig: config,
            scheme: .qemuPerfile
        )
        guard let subKeys = handle.qemuSubKeys else {
            try? handle.close()
            try? FileManager.default.removeItem(at: bundleURL)
            throw HVMError.encryption(.parseFailed(reason: "EncryptedBundleIO.create 未返子 keys"))
        }

        // 2. 主盘 LUKS qcow2
        let qemuImg: URL
        do {
            qemuImg = try QemuPaths.qemuImgBinary()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
        let mainDiskAbs = bundleURL.appendingPathComponent(
            "\(BundleLayout.disksDirName)/\(BundleLayout.mainDiskFileName(for: .qemu))"
        )
        do {
            try QcowLuksFactory.create(
                at: mainDiskAbs,
                sizeBytes: sizeGiB * (1 << 30),
                key: subKeys.qcow2Disk,
                qemuImg: qemuImg
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        // 3. OVMF VARS LUKS (仅 Windows guest)
        if config.guestOS == .windows {
            let qemuRoot: URL
            do {
                qemuRoot = try QemuPaths.resolveRoot()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: bundleURL)
                throw error
            }
            let template = qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-vars.fd")
            let nvramAbs = BundleLayout.nvramDir(bundleURL)
                .appendingPathComponent(BundleLayout.nvramLuksFileName)
            try? FileManager.default.createDirectory(at: BundleLayout.nvramDir(bundleURL),
                                                       withIntermediateDirectories: true)
            do {
                try OVMFVarsLuksFactory.create(
                    at: nvramAbs,
                    fromTemplate: template,
                    key: subKeys.qcow2Nvram,
                    qemuImg: qemuImg
                )
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: bundleURL)
                throw error
            }
        }

        // 4. close handle (QEMU 路径 noop, 仅清子 keys 引用)
        try handle.close()
    }

    /// 解析 --network 参数 → (mode, bridgedInterface).
    /// - "nat"             → (.user, nil)         (兼容老命名, 现行 NAT 走 user-mode)
    /// - "shared"          → (.vmnetShared, nil)
    /// - "host"            → (.vmnetHost, nil)
    /// - "bridged:<iface>" → (.vmnetBridged, "<iface>")
    /// - "none"            → (.none, nil)
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
