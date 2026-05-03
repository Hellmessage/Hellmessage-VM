// HVMEncryption/EncryptedBundleIO.swift
// 加密 VM 路由层 — 把 PR-1~7 全部底层模块缝合成一个干净接口.
// 设计稿 docs/v3/ENCRYPTION.md v2.3.
//
// 双 scheme:
//   vz-sparsebundle: 整 bundle 套加密 sparsebundle, attach 后 mountpoint 内是普通 .hvmz
//   qemu-perfile:    .hvmz 真实路径, 文件 in-place 加密 (config.yaml.enc / qcow2 LUKS / OVMF LUKS / swtpm key)
//
// API 简化原则:
//   - create() 只建"加密外壳" (sparsebundle 容器 / .hvmz 骨架 + config.yaml.enc + routing JSON)
//     磁盘 / nvram / tpm 创建由调用方 (CreateVMDialog / VMHost) 用 sub keys 自己做
//     EncryptedBundleIO 不管 disk 内容
//   - unlock() 解锁后返回 handle, 调用方读 handle.bundleURL / handle.qemuSubKeys
//   - close() 必调; VZ detach sparsebundle, QEMU 擦除内存中子 keys
//
// 跨机器 portable: routing JSON 在加密外, 含 KDF 参数. 目标机读 JSON + 输密码 → 派生
// 同 master KEK → 解锁. 不依赖 Keychain / iCloud / 任何本机状态.

import Foundation
import CryptoKit
import HVMBundle
import HVMCore

public enum EncryptedBundleIO {
    private static let log = HVMLog.logger("encryption.bundle")

    // MARK: - 公共类型

    /// create() 返回的句柄. 调用方完成磁盘 / config 创建后必须 close.
    public final class CreateHandle: @unchecked Sendable {
        public let scheme: EncryptionSpec.EncryptionScheme
        /// 调用方读写 bundle 的实际路径:
        ///   VZ:   <mountpoint>/<displayName>.hvmz (sparsebundle 已 attach)
        ///   QEMU: <parent>/<displayName>.hvmz (真实地址)
        public let bundleURL: URL
        /// QEMU 路径才有 (调用方注入 qemu-img / swtpm). VZ 路径 nil.
        public let qemuSubKeys: EncryptionKDF.SubKeySet?
        /// VZ 路径才有 (sparsebundle 实际位置). QEMU nil.
        public let sparsebundleURL: URL?
        /// VZ 路径才有 (mountpoint). QEMU nil.
        public let mountpoint: URL?
        /// routing JSON 落盘位置.
        public let routingJSONURL: URL

        private let lock = NSLock()
        private var closed = false

        fileprivate init(scheme: EncryptionSpec.EncryptionScheme,
                         bundleURL: URL,
                         qemuSubKeys: EncryptionKDF.SubKeySet?,
                         sparsebundleURL: URL?,
                         mountpoint: URL?,
                         routingJSONURL: URL) {
            self.scheme = scheme
            self.bundleURL = bundleURL
            self.qemuSubKeys = qemuSubKeys
            self.sparsebundleURL = sparsebundleURL
            self.mountpoint = mountpoint
            self.routingJSONURL = routingJSONURL
        }

        /// 完成创建. VZ detach sparsebundle. QEMU noop (子 keys 由 ARC 释放).
        /// 多次调用安全 (idempotent).
        public func close() throws {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            if let mp = mountpoint {
                try SparsebundleTool.detach(mountpoint: mp, force: false)
            }
        }

        deinit {
            // 兜底: 调用方忘 close → force detach
            if !closed, let mp = mountpoint {
                try? SparsebundleTool.detach(mountpoint: mp, force: true)
            }
        }
    }

    /// unlock() 返回的句柄. 与 CreateHandle 类似但额外携带解出的 VMConfig.
    public final class UnlockedHandle: @unchecked Sendable {
        public let scheme: EncryptionSpec.EncryptionScheme
        public let bundleURL: URL
        public let config: VMConfig
        public let qemuSubKeys: EncryptionKDF.SubKeySet?
        public let sparsebundleURL: URL?
        public let mountpoint: URL?

        private let lock = NSLock()
        private var closed = false

        fileprivate init(scheme: EncryptionSpec.EncryptionScheme,
                         bundleURL: URL,
                         config: VMConfig,
                         qemuSubKeys: EncryptionKDF.SubKeySet?,
                         sparsebundleURL: URL?,
                         mountpoint: URL?) {
            self.scheme = scheme
            self.bundleURL = bundleURL
            self.config = config
            self.qemuSubKeys = qemuSubKeys
            self.sparsebundleURL = sparsebundleURL
            self.mountpoint = mountpoint
        }

        public func close() throws {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            if let mp = mountpoint {
                try SparsebundleTool.detach(mountpoint: mp, force: false)
            }
        }

        deinit {
            if !closed, let mp = mountpoint {
                try? SparsebundleTool.detach(mountpoint: mp, force: true)
            }
        }
    }

    // MARK: - 公开 API

    /// 检测 bundle 路径是否走加密路径. 不解密.
    /// 用于 hvm-cli list / GUI 列表显示 "[加密]" 标记.
    public static func detectScheme(at bundleOrParentURL: URL,
                                     displayName: String? = nil) -> EncryptionSpec.EncryptionScheme? {
        let fm = FileManager.default

        // QEMU-perfile: 看 bundle 内 meta/encryption.json
        if bundleOrParentURL.pathExtension == "hvmz" {
            let qemuRoutingURL = RoutingJSON.locationForQemuBundle(bundleOrParentURL)
            if fm.fileExists(atPath: qemuRoutingURL.path) {
                return .qemuPerfile
            }
        }

        // VZ-sparsebundle: 看 .hvmz.sparsebundle 容器存在
        if let name = displayName {
            let sparsebundle = bundleOrParentURL
                .appendingPathComponent("\(name).hvmz.sparsebundle", isDirectory: true)
            if fm.fileExists(atPath: sparsebundle.path) {
                return .vzSparsebundle
            }
        }

        // 自身就是 sparsebundle?
        if bundleOrParentURL.pathExtension == "sparsebundle"
            && bundleOrParentURL.deletingPathExtension().pathExtension == "hvmz" {
            return .vzSparsebundle
        }

        return nil
    }

    /// 创建加密 VM 骨架. 不创建磁盘内容 (调用方负责).
    /// - parentDir: bundle / sparsebundle 父目录 (典型 ~/Library/Application Support/HVM/VMs)
    /// - displayName: VM 显示名 + 决定文件名
    /// - password: 用户输入的明文密码 (跨机器 portable 唯一来源)
    /// - baseConfig: 初始 VMConfig (磁盘 / 网络等业务字段; encryption 字段会被覆盖)
    /// - scheme: vzSparsebundle 或 qemuPerfile
    /// - sparsebundleSizeBytes: VZ 路径 sparsebundle 容器上限 (sparse, 实际占用按写入增长)
    public static func create(parentDir: URL,
                              displayName: String,
                              password: String,
                              baseConfig: VMConfig,
                              scheme: EncryptionSpec.EncryptionScheme,
                              sparsebundleSizeBytes: UInt64 = 64 * 1024 * 1024 * 1024) throws -> CreateHandle {
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // 生成 salt + master KEK (跨机器 portable 关键)
        let salt = try PasswordKDF.generateSalt()
        let master = try PasswordKDF.deriveMasterKey(password: password, salt: salt)

        var config = baseConfig
        config.encryption = EncryptionSpec(enabled: true,
                                            scheme: scheme,
                                            createdAt: Date())

        switch scheme {
        case .vzSparsebundle:
            return try createVZ(parentDir: parentDir,
                                 displayName: displayName,
                                 password: password,
                                 salt: salt,
                                 sparsebundleSize: sparsebundleSizeBytes,
                                 config: config,
                                 vmId: config.id)

        case .qemuPerfile:
            return try createQEMU(parentDir: parentDir,
                                   displayName: displayName,
                                   master: master,
                                   salt: salt,
                                   config: config,
                                   vmId: config.id)
        }
    }

    /// 用密码解锁加密 VM. 错密码抛 .wrongPassword.
    /// - bundlePath: 对 VZ 是 .hvmz.sparsebundle 路径; QEMU 是 .hvmz 路径
    public static func unlock(bundlePath: URL,
                              password: String) throws -> UnlockedHandle {
        // 1. 读 routing JSON 拿 KDF 参数 + scheme (跨机器 portable 入口)
        let scheme: EncryptionSpec.EncryptionScheme
        let routingURL: URL
        if bundlePath.pathExtension == "sparsebundle" {
            scheme = .vzSparsebundle
            routingURL = RoutingJSON.locationForSparsebundle(bundlePath)
        } else {
            scheme = .qemuPerfile
            routingURL = RoutingJSON.locationForQemuBundle(bundlePath)
        }
        let routing = try RoutingJSON.read(from: routingURL)
        guard routing.scheme == scheme else {
            throw HVMError.encryption(.parseFailed(
                reason: "routing scheme=\(routing.scheme.rawValue) 与 bundle 路径 (\(scheme.rawValue)) 不一致"))
        }

        // 2. PBKDF2 派生 master KEK
        let master = try PasswordKDF.deriveMasterKey(password: password,
                                                      salt: routing.kdfSalt,
                                                      iterations: routing.kdfIterations)

        // 3. 走 scheme 分流
        switch scheme {
        case .vzSparsebundle:
            return try unlockVZ(sparsebundleURL: bundlePath,
                                 password: password,
                                 vmId: routing.vmId)

        case .qemuPerfile:
            return try unlockQEMU(bundleURL: bundlePath, master: master)
        }
    }

    // MARK: - VZ 路径

    private static func createVZ(parentDir: URL,
                                  displayName: String,
                                  password: String,
                                  salt: Data,
                                  sparsebundleSize: UInt64,
                                  config: VMConfig,
                                  vmId: UUID) throws -> CreateHandle {
        let sparsebundleURL = parentDir.appendingPathComponent(
            "\(displayName).hvmz.sparsebundle", isDirectory: true)

        // 1. 创建 sparsebundle (hdiutil 走自家 PBKDF2)
        let uuid8 = String(vmId.uuidString.lowercased().prefix(8))
        try SparsebundleTool.create(at: sparsebundleURL,
                                     password: password,
                                     options: .init(sizeBytes: sparsebundleSize,
                                                    volumeName: "HVM-\(uuid8)"))

        // 2. attach 到 mountpoint
        let mountpoint = HVMPaths.mountpointFor(uuid: vmId)
        try? FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        _ = try SparsebundleTool.attach(at: sparsebundleURL,
                                         password: password,
                                         mountpoint: mountpoint)

        // 3. mountpoint 内创建 .hvmz + 走 BundleIO.create
        let bundleURL = mountpoint.appendingPathComponent(
            "\(displayName).hvmz", isDirectory: true)
        do {
            try BundleIO.create(at: bundleURL, config: config)
        } catch {
            // 创建失败 → detach + 删 sparsebundle
            try? SparsebundleTool.detach(mountpoint: mountpoint, force: true)
            try? FileManager.default.removeItem(at: sparsebundleURL)
            throw error
        }

        // 4. 写 routing JSON (与 sparsebundle 同级, 明文)
        let routing = RoutingMetadata(vmId: vmId,
                                       scheme: .vzSparsebundle,
                                       displayName: displayName,
                                       kdfSalt: salt)
        let routingURL = RoutingJSON.locationForSparsebundle(sparsebundleURL)
        do {
            try RoutingJSON.write(routing, to: routingURL)
        } catch {
            try? SparsebundleTool.detach(mountpoint: mountpoint, force: true)
            try? FileManager.default.removeItem(at: sparsebundleURL)
            throw error
        }

        Self.log.info("EncryptedBundleIO create VZ: \(displayName, privacy: .public) sparsebundle=\(sparsebundleURL.lastPathComponent, privacy: .public)")

        return CreateHandle(scheme: .vzSparsebundle,
                            bundleURL: bundleURL,
                            qemuSubKeys: nil,
                            sparsebundleURL: sparsebundleURL,
                            mountpoint: mountpoint,
                            routingJSONURL: routingURL)
    }

    private static func unlockVZ(sparsebundleURL: URL,
                                  password: String,
                                  vmId: UUID) throws -> UnlockedHandle {
        let mountpoint = HVMPaths.mountpointFor(uuid: vmId)
        try? FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        // attach (密码错抛 wrongPassword)
        _ = try SparsebundleTool.attach(at: sparsebundleURL,
                                         password: password,
                                         mountpoint: mountpoint)

        // 找 mountpoint 下唯一 .hvmz 子目录
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: mountpoint.path)) ?? []
        guard let hvmzName = entries.first(where: { $0.hasSuffix(".hvmz") }) else {
            try? SparsebundleTool.detach(mountpoint: mountpoint, force: true)
            throw HVMError.encryption(.parseFailed(
                reason: "sparsebundle 内未找到 .hvmz 子目录"))
        }
        let bundleURL = mountpoint.appendingPathComponent(hvmzName, isDirectory: true)

        // 读 config
        let config: VMConfig
        do {
            config = try BundleIO.load(from: bundleURL)
        } catch {
            try? SparsebundleTool.detach(mountpoint: mountpoint, force: true)
            throw error
        }

        return UnlockedHandle(scheme: .vzSparsebundle,
                              bundleURL: bundleURL,
                              config: config,
                              qemuSubKeys: nil,
                              sparsebundleURL: sparsebundleURL,
                              mountpoint: mountpoint)
    }

    // MARK: - QEMU 路径

    private static func createQEMU(parentDir: URL,
                                    displayName: String,
                                    master: MasterKey,
                                    salt: Data,
                                    config: VMConfig,
                                    vmId: UUID) throws -> CreateHandle {
        let bundleURL = parentDir.appendingPathComponent(
            "\(displayName).hvmz", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            throw HVMError.bundle(.alreadyExists(path: bundleURL.path))
        }

        // 1. 派生 4 子 keys
        let subKeys = EncryptionKDF.deriveAll(masterKey: master)

        // 2. 创建 bundle 骨架 (mkdir + 子目录)
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
            try FileManager.default.createDirectory(at: BundleLayout.disksDir(bundleURL),
                                                     withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: BundleLayout.metaDir(bundleURL),
                                                     withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: BundleLayout.logsDir(bundleURL),
                                                     withIntermediateDirectories: true)
            switch config.guestOS {
            case .linux, .windows:
                try FileManager.default.createDirectory(at: BundleLayout.nvramDir(bundleURL),
                                                         withIntermediateDirectories: true)
            case .macOS:
                // QEMU 后端不支持 macOS guest, validate() 会拒. 但 mkdir auxiliary 仍兜底
                try FileManager.default.createDirectory(at: BundleLayout.auxiliaryDir(bundleURL),
                                                         withIntermediateDirectories: true)
            }
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw HVMError.bundle(.writeFailed(reason: "\(error)", path: bundleURL.path))
        }

        // 3. 加密 config.yaml.enc
        do {
            try EncryptedConfigIO.save(config: config, to: bundleURL, key: subKeys.config)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        // 4. 写 routing JSON (bundle 内 meta/encryption.json, 明文)
        let routing = RoutingMetadata(vmId: vmId,
                                       scheme: .qemuPerfile,
                                       displayName: displayName,
                                       kdfSalt: salt)
        let routingURL = RoutingJSON.locationForQemuBundle(bundleURL)
        do {
            try RoutingJSON.write(routing, to: routingURL)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        Self.log.info("EncryptedBundleIO create QEMU: \(displayName, privacy: .public) bundle=\(bundleURL.lastPathComponent, privacy: .public)")

        return CreateHandle(scheme: .qemuPerfile,
                            bundleURL: bundleURL,
                            qemuSubKeys: subKeys,
                            sparsebundleURL: nil,
                            mountpoint: nil,
                            routingJSONURL: routingURL)
    }

    private static func unlockQEMU(bundleURL: URL,
                                    master: MasterKey) throws -> UnlockedHandle {
        let subKeys = EncryptionKDF.deriveAll(masterKey: master)
        // EncryptedConfigIO.load 错 key → .wrongPassword
        let config = try EncryptedConfigIO.load(from: bundleURL, key: subKeys.config)
        return UnlockedHandle(scheme: .qemuPerfile,
                              bundleURL: bundleURL,
                              config: config,
                              qemuSubKeys: subKeys,
                              sparsebundleURL: nil,
                              mountpoint: nil)
    }
}
