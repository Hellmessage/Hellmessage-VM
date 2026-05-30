// VMControl+Encryption.swift — 整 VM 加密事务包装 (业务页 #3).
//
// 视图无关的加密/解密/rekey 收口, 给新 GUI dialog + (未来) CLI 复用. 内部解析 qemuImg +
// Win OVMF VARS 模板路径 (跟 addDiskEncrypted 同款走 QemuPaths), 业务侧不碰后端路径.
// 底层调 HVMEncryption 的三个 Operation; 仅 qemuPerfile scheme (VZ-sparsebundle 推后).
//
// progress 回调在**调用线程** (Operation 同步执行), 调用方 (store) 负责 hop 到 main.

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMQemu

public extension VMControl {

    // MARK: - 加密 (明文 → 加密)

    /// 加密明文 VM (冷迁移, 分钟级). 内部解析 qemuImg + Win OVMF 模板. requireStopped 强制.
    /// engine/guestOS 校验由 Operation 层做 (拒已加密 / 拒非 QEMU / 拒 macOS guest). 返 tpmReset.
    @discardableResult
    static func encryptVM(bundleURL: URL, password: String,
                          progress: @escaping (String) -> Void) throws -> Bool {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        let qemuImg = try QemuPaths.qemuImgBinary()
        // Win guest 才需 OVMF VARS 模板 (efi-vars LUKS 化); 读明文 config 判 guestOS
        let config = try BundleIO.load(from: bundleURL)
        var ovmfTemplate: URL? = nil
        if config.guestOS == .windows {
            ovmfTemplate = try QemuPaths.resolveRoot()
                .appendingPathComponent("share/qemu/edk2-aarch64-vars.fd")
        }
        let result = try EncryptVMOperation.encrypt(
            bundleURL: bundleURL, password: password,
            qemuImg: qemuImg, ovmfVarsTemplate: ovmfTemplate,
            progressLog: progress)
        return result.tpmReset
    }

    // MARK: - 解密 (加密 → 明文)

    /// 解密加密 VM (冷迁移, 分钟级). 转明文后 disks 仍 qcow2 (不强转 raw). 无 TPM 重置.
    static func decryptVM(bundleURL: URL, password: String,
                          progress: @escaping (String) -> Void) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        let qemuImg = try QemuPaths.qemuImgBinary()
        _ = try DecryptVMOperation.decrypt(
            bundleURL: bundleURL, password: password,
            qemuImg: qemuImg, progressLog: progress)
    }

    // MARK: - 改密 (rekey)

    /// 改密加密 VM (LUKS keyslot 重写, 毫秒级 + config 原子写). 老+新密码都活 (加 keyslot).
    /// 新密码须 ≠ 原密码 (调用方校验). Win guest 重置 TPM. 返 tpmReset.
    @discardableResult
    static func rekeyVM(bundleURL: URL, oldPassword: String, newPassword: String,
                        progress: @escaping (String) -> Void) throws -> Bool {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        let qemuImg = try QemuPaths.qemuImgBinary()
        let result = try RekeyVMOperation.rekey(
            bundleURL: bundleURL, oldPassword: oldPassword, newPassword: newPassword,
            qemuImg: qemuImg, progressLog: progress)
        return result.tpmReset
    }
}
