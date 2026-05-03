// HVMEncryption/OVMFVarsLuksFactory.swift
// QEMU 路径加密 VM 的 OVMF VARS 加密化. 把 stock raw `edk2-aarch64-vars.fd` 模板
// 转成 LUKS 加密 qcow2 (efi-vars.qcow2), QEMU 启动期走 -drive file.driver=luks 加载.
//
// 设计稿 docs/v3/ENCRYPTION.md v2.2 "QEMU 路径 加密点四件套".
//
// 流程 (创建加密 Win VM 时):
//   1. CreateVMDialog / EncryptedBundleIO 拿到 master KEK + HKDF 派生 nvramKey (32B)
//   2. OVMFVarsLuksFactory.create(at: <bundle>/nvram/efi-vars.qcow2,
//                                  fromTemplate: <qemuRoot>/share/qemu/edk2-aarch64-vars.fd,
//                                  key: nvramKey, qemuImg: ...)
//   3. qemu-img convert -f raw -O qcow2 -o encrypt.format=luks,encrypt.key-secret=sec0 ...
//   4. 完成: efi-vars.qcow2 是 LUKS qcow2, 内容等价于原 64 KiB raw 模板字节
//
// 启动期 (PR-9 接入):
//   QEMU argv 加 -drive if=pflash,driver=qcow2,file.filename=<path>,file.driver=luks,
//                  file.key-secret=sec_nvram + -object secret,id=sec_nvram,file=<key file>
//
// 不做:
//   - 内容修改 / 写入 (QEMU 启动后自动写, HVM 不动)
//   - 从已加密 qcow2 转回 raw (decrypt 路径 PR-10 走 hvm-cli decrypt)
//   - 改密 (走 QcowLuksFactory.rekey 即可, 同 LUKS qcow2 路径)

import Foundation
import CryptoKit
import HVMCore

public enum OVMFVarsLuksFactory {
    private static let log = HVMLog.logger("encryption.ovmfvars")

    /// 把 raw OVMF VARS 模板转成 LUKS qcow2 容器, 内容是模板原 raw 字节 (qemu-img convert 自动 padding).
    /// - Parameter url: 目标 qcow2 路径 (典型 <bundle>/nvram/efi-vars.qcow2). 已存在抛错.
    /// - Parameter templateURL: stock OVMF VARS 模板 raw fd 文件 (典型 <qemuRoot>/share/qemu/edk2-aarch64-vars.fd).
    /// - Parameter key: HKDF 派生的 nvram-key (32 字节).
    /// - Parameter qemuImg: HVM 包内 qemu-img 路径.
    public static func create(at url: URL,
                              fromTemplate templateURL: URL,
                              key: SymmetricKey,
                              qemuImg: URL) throws {
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: templateURL.path))
        }
        if FileManager.default.fileExists(atPath: url.path) {
            throw HVMError.storage(.diskAlreadyExists(path: url.path))
        }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        Self.log.info("OVMF VARS LUKS create: \(url.lastPathComponent, privacy: .public) ← \(templateURL.lastPathComponent, privacy: .public)")
        do {
            try runQemuImg(qemuImg: qemuImg, verb: "convert", args: [
                "--object", "secret,id=sec0,file=\(secret.path)",
                "-f", "raw",
                "-O", "qcow2",
                "-o", "encrypt.format=luks,encrypt.key-secret=sec0,encrypt.cipher-alg=aes-256,encrypt.cipher-mode=xts",
                templateURL.path,
                url.path,
            ])
        } catch {
            // convert 失败 → 清半成品
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // SecretKeyFile 已抽到 HVMEncryption/LuksSecretFile.swift (公共).

    private static func runQemuImg(qemuImg: URL, verb: String, args: [String]) throws {
        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = [verb] + args
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            throw HVMError.encryption(.qemuImgFailed(
                verb: verb, exitCode: -1,
                stderr: "无法启动 qemu-img: \(error)"
            ))
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            Self.log.error("qemu-img \(verb, privacy: .public) 失败 status=\(proc.terminationStatus) stderr=\(stderr, privacy: .public)")
            throw HVMError.encryption(.qemuImgFailed(
                verb: verb,
                exitCode: proc.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
    }
}
