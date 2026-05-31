// VMControl+Create.swift — VM 创建 (CLI create + GUI 创建向导单一来源).
// 明文走 BundleIO + DiskFactory; 加密走 EncryptedBundleIO + QcowLuksFactory + OVMFVarsLuksFactory.
// 失败一律清残留 bundle (绝不留 partial). engine 恒 qemu (QEMU-only).
//
// import-disk (导入现成镜像) 不在此 — 仅 CLI 支持, 留在 CreateCommand (GUI v1 不接).

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMStorage
import HVMQemu

public extension VMControl {

    /// 创建参数 (CLI + GUI 共用). 校验由调用方先做 (GUI canAdvance / CLI argv);
    /// create 内部仍做创建不变量校验 (ISO 存在 / MAC 合法 / 卷空间), 防落出坏 bundle.
    struct CreateSpec: Sendable {
        public var name: String
        public var guestOS: GuestOSType
        public var cpuCount: Int
        public var memoryGiB: UInt64
        public var diskGiB: UInt64
        public var networkMode: NetworkMode
        public var bridgedInterface: String?
        public var macAddress: String?       // nil → 随机 locally-administered
        public var installerISO: String?      // 装机 ISO 绝对路径 (create 必填)
        public var parentDir: URL?            // nil → HVMPaths.vmsRoot
        public var windows: WindowsSpec?      // guestOS==.windows 时; nil → 默认 WindowsSpec()
        public var encrypt: Bool
        public var password: String?          // encrypt 时必填

        public init(name: String,
                    guestOS: GuestOSType,
                    cpuCount: Int = 4,
                    memoryGiB: UInt64 = 4,
                    diskGiB: UInt64 = 64,
                    networkMode: NetworkMode = .user,
                    bridgedInterface: String? = nil,
                    macAddress: String? = nil,
                    installerISO: String? = nil,
                    parentDir: URL? = nil,
                    windows: WindowsSpec? = nil,
                    encrypt: Bool = false,
                    password: String? = nil) {
            self.name = name
            self.guestOS = guestOS
            self.cpuCount = cpuCount
            self.memoryGiB = memoryGiB
            self.diskGiB = diskGiB
            self.networkMode = networkMode
            self.bridgedInterface = bridgedInterface
            self.macAddress = macAddress
            self.installerISO = installerISO
            self.parentDir = parentDir
            self.windows = windows
            self.encrypt = encrypt
            self.password = password
        }
    }

    /// create 结果 — bundleURL + 落盘所用 config (CLI 打印 / GUI 选中新 VM 用).
    struct CreateResult: Sendable {
        public let bundleURL: URL
        public let config: VMConfig
    }

    /// 创建明文/加密 VM, 返回 bundleURL + config. 失败抛 HVMError 并清残留 bundle.
    @discardableResult
    static func create(_ spec: CreateSpec) throws -> CreateResult {
        let engine: Engine = .qemu   // QEMU-only

        // ---- 创建不变量校验 ----
        guard let isoPath = spec.installerISO else {
            throw HVMError.config(.missingField(name: "iso"))
        }
        try ISOValidator.validate(at: isoPath)

        let macAddr: String
        if let explicit = spec.macAddress {
            guard NetworkSpec.isValidMAC(explicit) else {
                throw HVMError.config(.invalidEnum(field: "mac", raw: explicit,
                                                   allowed: ["xx:xx:xx:xx:xx:xx"]))
            }
            macAddr = explicit
        } else {
            macAddr = NetworkSpec.generateRandomMAC()
        }

        let parentDir = spec.parentDir ?? URL(fileURLWithPath: HVMPaths.vmsRoot.path,
                                              isDirectory: true)
        try HVMPaths.ensure(parentDir)
        let bundleURL = parentDir.appendingPathComponent("\(spec.name).hvmz", isDirectory: true)

        try VolumeInfo.assertSpaceAvailable(
            at: parentDir.path,
            requiredBytes: spec.diskGiB * (1 << 30)
        )

        // ---- VMConfig ----
        let mainFormat: DiskFormat = .qcow2
        let mainDiskFile = "\(BundleLayout.disksDirName)/\(BundleLayout.mainDiskFileName(for: engine))"
        let mainDisk = DiskSpec(role: .main, path: mainDiskFile,
                                sizeGiB: spec.diskGiB, format: mainFormat)
        let config = VMConfig(
            displayName: spec.name,
            guestOS: spec.guestOS,
            engine: engine,
            cpuCount: spec.cpuCount,
            memoryMiB: spec.memoryGiB * 1024,
            disks: [mainDisk],
            networks: [NetworkSpec(
                mode: spec.networkMode,
                macAddress: macAddr,
                bridgedInterface: spec.bridgedInterface
            )],
            installerISO: isoPath,
            bootFromDiskOnly: false,
            linux: spec.guestOS == .linux ? LinuxSpec() : nil,
            windows: spec.guestOS == .windows ? (spec.windows ?? WindowsSpec()) : nil
        )

        // ---- 加密 / 明文分流 ----
        if spec.encrypt {
            guard let password = spec.password, !password.isEmpty else {
                throw HVMError.config(.missingField(name: "password"))
            }
            try createEncrypted(parentDir: parentDir, bundleURL: bundleURL,
                                password: password, config: config, sizeGiB: spec.diskGiB)
        } else {
            try BundleIO.create(at: bundleURL, config: config)
            let qemuImg = try? QemuPaths.qemuImgBinary()
            let mainDiskAbs = bundleURL.appendingPathComponent(mainDiskFile)
            do {
                try DiskFactory.create(at: mainDiskAbs, sizeGiB: spec.diskGiB,
                                       format: mainFormat, qemuImg: qemuImg)
            } catch {
                try? FileManager.default.removeItem(at: bundleURL)
                throw error
            }
        }
        return CreateResult(bundleURL: bundleURL, config: config)
    }

    /// 创建加密 QEMU VM (EncryptedBundleIO + QcowLuksFactory + OVMFVarsLuksFactory). 失败清残留.
    private static func createEncrypted(parentDir: URL,
                                        bundleURL: URL,
                                        password: String,
                                        config: VMConfig,
                                        sizeGiB: UInt64) throws {
        // 1. 加密外壳 (config.yaml.enc + meta/encryption.json)
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
}
