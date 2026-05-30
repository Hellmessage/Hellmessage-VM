// VMControl+Config.swift — 配置编辑 + 磁盘操作 (业务页 #2, docs/v4/NEW_GUI_VM_DETAIL.md V1).
//
// 视图无关的配置保存层, 收口老 AppModel.saveConfig + DiskFactory 调用. CLI + 新 GUI 共用.
// 明文走 BundleIO; 加密走 EncryptedConfigIO (调用方传 config subkey, 解锁流程 V2 产出).
// 磁盘明文走 DiskFactory (raw ftruncate / qcow2 qemu-img); 加密 LUKS 盘留 V4.

import Foundation
import CryptoKit
import HVMBundle
import HVMCore
import HVMEncryption
import HVMStorage
import HVMQemu
import HVMIPC

public extension VMControl {

    // MARK: - 配置保存 (明文 / 加密分流)

    /// 改明文 VM config: load → mutate → save (YAML 原子写). requireStopped 时 running 抛 .busy.
    /// 加密 VM (无 config.yaml, BundleIO.load 抛错) 请走 saveConfigEncrypted.
    static func saveConfig(bundleURL: URL,
                           requireStopped: Bool = true,
                           mutate: (inout VMConfig) throws -> Void) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: requireStopped)
        var config = try BundleIO.load(from: bundleURL)
        try mutate(&config)
        try BundleIO.save(config: config, to: bundleURL)
    }

    /// 改加密 VM config: 用 config subkey 解密当前 config.yaml.enc → mutate → 重密.
    /// configKey 由解锁流程 (V2) 派生 (EncryptionKDF.SubKeySet.config). requireStopped 同上.
    static func saveConfigEncrypted(bundleURL: URL,
                                    requireStopped: Bool = true,
                                    configKey: SymmetricKey,
                                    mutate: (inout VMConfig) throws -> Void) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: requireStopped)
        var config = try EncryptedConfigIO.load(from: bundleURL, key: configKey)
        try mutate(&config)
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: configKey)
    }

    // MARK: - 磁盘操作 (明文 raw/qcow2; 加密 LUKS 留 V4)

    /// 加数据盘: DiskFactory.create (engine 决定 raw/qcow2) + config 追加 DiskSpec. 必 stopped.
    static func addDisk(bundleURL: URL, sizeGiB: UInt64) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try BundleIO.load(from: bundleURL)
        let engine = config.engine
        let format: DiskFormat = (engine == .qemu) ? .qcow2 : .raw
        let uuid8 = DiskFactory.newDataDiskUUID8()
        let fileName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: engine)
        let relPath = "\(BundleLayout.disksDirName)/\(fileName)"
        let absURL = bundleURL.appendingPathComponent(relPath)
        let qemuImg = (format == .qcow2) ? try QemuPaths.qemuImgBinary() : nil
        try DiskFactory.create(at: absURL, sizeGiB: sizeGiB, format: format, qemuImg: qemuImg)
        config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: sizeGiB, format: format))
        try BundleIO.save(config: config, to: bundleURL)
    }

    /// 扩盘 (主盘或数据盘, 按 diskPath 匹配): DiskFactory.grow + 更新 DiskSpec.sizeGiB. 只增不减.
    static func resizeDisk(bundleURL: URL, diskPath: String, toGiB: UInt64) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try BundleIO.load(from: bundleURL)
        guard let idx = config.disks.firstIndex(where: { $0.path == diskPath }) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: diskPath))
        }
        guard toGiB > config.disks[idx].sizeGiB else {
            throw HVMError.storage(.shrinkNotSupported(
                currentBytes: Int64(config.disks[idx].sizeGiB) << 30,
                requestedBytes: Int64(toGiB) << 30))
        }
        let absURL = bundleURL.appendingPathComponent(diskPath)
        let format = config.disks[idx].format
        let qemuImg = (format == .qcow2) ? try QemuPaths.qemuImgBinary() : nil
        try DiskFactory.grow(at: absURL, toGiB: toGiB, format: format, qemuImg: qemuImg)
        config.disks[idx].sizeGiB = toGiB
        try BundleIO.save(config: config, to: bundleURL)
    }

    /// 删数据盘: 移除 DiskSpec + 物理删文件. 主盘 (role=.main) 不可删.
    static func deleteDisk(bundleURL: URL, diskPath: String) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try BundleIO.load(from: bundleURL)
        guard let idx = config.disks.firstIndex(where: { $0.path == diskPath }) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: diskPath))
        }
        guard config.disks[idx].role == .data else {
            throw HVMError.backend(.configInvalid(field: "disk", reason: "主盘不可删除"))
        }
        let absURL = bundleURL.appendingPathComponent(diskPath)
        config.disks.remove(at: idx)
        try BundleIO.save(config: config, to: bundleURL)
        try? DiskFactory.delete(at: absURL)   // 文件删失败不回滚 config (盘已从配置移除)
    }

    // MARK: - 加密 VM 磁盘操作 (LUKS qcow2; 调用方传解锁后的 qcow2Disk + config subkey)

    /// 加密 VM 加数据盘: QcowLuksFactory.create (LUKS) + EncryptedConfigIO 追加 DiskSpec.
    static func addDiskEncrypted(bundleURL: URL, sizeGiB: UInt64,
                                 diskKey: SymmetricKey, configKey: SymmetricKey) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try EncryptedConfigIO.load(from: bundleURL, key: configKey)
        // 加密 VM 必 qemu/qcow2
        let uuid8 = DiskFactory.newDataDiskUUID8()
        let fileName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: .qemu)
        let relPath = "\(BundleLayout.disksDirName)/\(fileName)"
        let absURL = bundleURL.appendingPathComponent(relPath)
        let qemuImg = try QemuPaths.qemuImgBinary()
        try QcowLuksFactory.create(at: absURL, sizeBytes: sizeGiB << 30, key: diskKey, qemuImg: qemuImg)
        config.disks.append(DiskSpec(role: .data, path: relPath, sizeGiB: sizeGiB, format: .qcow2))
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: configKey)
    }

    /// 加密 VM 扩盘: QcowLuksFactory.grow. 只增不减.
    static func resizeDiskEncrypted(bundleURL: URL, diskPath: String, toGiB: UInt64,
                                    diskKey: SymmetricKey, configKey: SymmetricKey) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try EncryptedConfigIO.load(from: bundleURL, key: configKey)
        guard let idx = config.disks.firstIndex(where: { $0.path == diskPath }) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: diskPath))
        }
        guard toGiB > config.disks[idx].sizeGiB else {
            throw HVMError.storage(.shrinkNotSupported(
                currentBytes: Int64(config.disks[idx].sizeGiB) << 30,
                requestedBytes: Int64(toGiB) << 30))
        }
        let absURL = bundleURL.appendingPathComponent(diskPath)
        let qemuImg = try QemuPaths.qemuImgBinary()
        try QcowLuksFactory.grow(at: absURL, toBytes: toGiB << 30, key: diskKey, qemuImg: qemuImg)
        config.disks[idx].sizeGiB = toGiB
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: configKey)
    }

    /// 加密 VM 删数据盘: 移除 DiskSpec + 删文件. 主盘不可删.
    static func deleteDiskEncrypted(bundleURL: URL, diskPath: String,
                                    configKey: SymmetricKey) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        var config = try EncryptedConfigIO.load(from: bundleURL, key: configKey)
        guard let idx = config.disks.firstIndex(where: { $0.path == diskPath }) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: diskPath))
        }
        guard config.disks[idx].role == .data else {
            throw HVMError.backend(.configInvalid(field: "disk", reason: "主盘不可删除"))
        }
        let absURL = bundleURL.appendingPathComponent(diskPath)
        config.disks.remove(at: idx)
        try EncryptedConfigIO.save(config: config, to: bundleURL, key: configKey)
        try? DiskFactory.delete(at: absURL)
    }

    // MARK: - 剪贴板共享 (可 running 热改)

    /// 切剪贴板共享: 落 config (requireStopped=false 可 running 改) + running 时 IPC 即时生效.
    static func setClipboardSharing(bundleURL: URL, enabled: Bool) throws {
        try saveConfig(bundleURL: bundleURL, requireStopped: false) { config in
            config.clipboardSharingEnabled = enabled
        }
        // running → IPC 即时切换 (vdagent). 未运行则下次启动生效.
        guard let holder = BundleLock.inspect(bundleURL: bundleURL),
              !holder.socketPath.isEmpty else { return }
        let req = IPCRequest(op: IPCOp.clipboardSetEnabled.rawValue,
                             args: ["enabled": enabled ? "1" : "0"])
        _ = try? SocketClient.request(socketPath: holder.socketPath, request: req, timeoutSec: 3)
    }

    // MARK: - 内部

    /// requireStopped 时检查 running, 占用抛 .busy
    private static func assertStoppedIfNeeded(bundleURL: URL, requireStopped: Bool) throws {
        if requireStopped, BundleLock.isBusy(bundleURL: bundleURL) {
            let holder = BundleLock.inspect(bundleURL: bundleURL)
            throw HVMError.bundle(.busy(pid: holder?.pid ?? 0, holderMode: holder?.mode ?? "runtime"))
        }
    }
}
