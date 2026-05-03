// HVMEncryption/QcowLuksFactory.swift
// QEMU 路径加密: qcow2 native LUKS create / resize / rekey 包.
// 走 HVM 包内 qemu-img (Bundle.main/Resources/QEMU/bin/qemu-img).
//
// 设计稿 docs/v3/ENCRYPTION.md v2.2.
//
// API:
//   - create(at:, sizeBytes:, key:, qemuImg:) — qemu-img create LUKS qcow2
//   - grow(at:, toBytes:, key:, qemuImg:)     — qemu-img resize (LUKS 需要 key 解 header)
//   - rekey(at:, oldKey:, newKey:, qemuImg:)  — 两步 amend (add new + remove old)
//   - isLuksEncrypted(at:, qemuImg:)          — 探测, 不需 key
//
// 密钥注入安全:
//   key (32 字节 SymmetricKey) 写到 0o600 临时文件 (NSTemporaryDirectory + UUID 后缀),
//   qemu-img 用 --object secret,file=<path> 一次性读完, 完成后立即 unlink.
//   不走 ps 可见的 secret-key=base64,data=... 形式.
//
// LUKS rekey 两步法 (qemu-img amend, HVM 包 qemu-img 10.2 没有 reencrypt 子命令):
//   step 1: amend -o "encrypt.new-secret=sec_new,encrypt.state=active" → 加新 keyslot
//   step 2: amend -o "encrypt.old-secret=sec_old,encrypt.state=inactive" → 销毁老 keyslot
//   step 1 失败 → 直接报错, 数据不动
//   step 2 失败 → 抛 .luksRekeyHalfDone (老 + 新 keyslot 都激活, 用户重试可恢复)
//
// 不做:
//   - import 现有明文 qcow2 转 LUKS (用户走 qemu-img convert + create)
//   - keyslot 多版本管理 (LUKS 有 8 keyslot, HVM 只用 0 + 1, 不暴露)
//   - 性能调优 (encrypt.iter-time PBKDF time, 默认 2000ms 即可)

import Foundation
import CryptoKit
import HVMCore

public enum QcowLuksFactory {
    private static let log = HVMLog.logger("encryption.qcow2luks")

    // MARK: - 公开 API

    /// 创建 LUKS qcow2. 已存在文件抛 .storage(.diskAlreadyExists).
    public static func create(at url: URL,
                              sizeBytes: UInt64,
                              key: SymmetricKey,
                              qemuImg: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw HVMError.storage(.diskAlreadyExists(path: url.path))
        }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        Self.log.info("qcow2 LUKS create: \(url.lastPathComponent, privacy: .public) size=\(sizeBytes)b")
        do {
            try runQemuImg(qemuImg: qemuImg, verb: "create", args: [
                "--object", "secret,id=sec0,file=\(secret.path)",
                "-f", "qcow2",
                "-o", "encrypt.format=luks,encrypt.key-secret=sec0,encrypt.cipher-alg=aes-256,encrypt.cipher-mode=xts",
                url.path,
                "\(sizeBytes)",
            ])
        } catch {
            // create 失败 — 清掉半成品 (qemu-img 通常自动清, 兜底)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// 扩容 (resize). LUKS qcow2 resize 需要 key 解 header.
    /// toBytes 必须 > 当前 virtual size; 缩容由调用方拒绝 (qemu-img 也会拒).
    public static func grow(at url: URL,
                            toBytes: UInt64,
                            key: SymmetricKey,
                            qemuImg: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: url.path))
        }
        let secret = try LuksSecretFile(key: key)
        defer { secret.cleanup() }

        Self.log.info("qcow2 LUKS grow: \(url.lastPathComponent, privacy: .public) → \(toBytes)b")
        try runQemuImg(qemuImg: qemuImg, verb: "resize", args: [
            "--object", "secret,id=sec0,file=\(secret.path)",
            "--image-opts",
            "driver=qcow2,file.filename=\(url.path),encrypt.key-secret=sec0",
            "\(toBytes)",
        ])
    }

    /// 改密 (rekey, 两步法). step 1 加新 keyslot, step 2 销毁老 keyslot.
    /// step 2 失败 → 抛 .luksRekeyHalfDone (此时老 + 新两个 keyslot 都激活, 用户重试 rekey 可恢复).
    public static func rekey(at url: URL,
                             oldKey: SymmetricKey,
                             newKey: SymmetricKey,
                             qemuImg: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HVMError.storage(.ioError(errno: ENOENT, path: url.path))
        }
        let oldSecret = try LuksSecretFile(key: oldKey)
        defer { oldSecret.cleanup() }
        let newSecret = try LuksSecretFile(key: newKey)
        defer { newSecret.cleanup() }

        // step 1: 加新 keyslot (state=active + new-secret)
        Self.log.info("qcow2 LUKS rekey step 1 (add new keyslot): \(url.lastPathComponent, privacy: .public)")
        try runQemuImg(qemuImg: qemuImg, verb: "amend", args: [
            "--object", "secret,id=sec_old,file=\(oldSecret.path)",
            "--object", "secret,id=sec_new,file=\(newSecret.path)",
            "-o", "encrypt.new-secret=sec_new,encrypt.state=active",
            "--image-opts",
            "driver=qcow2,file.filename=\(url.path),encrypt.key-secret=sec_old",
        ])

        // step 2: 销毁老 keyslot (state=inactive + old-secret)
        Self.log.info("qcow2 LUKS rekey step 2 (remove old keyslot): \(url.lastPathComponent, privacy: .public)")
        do {
            try runQemuImg(qemuImg: qemuImg, verb: "amend", args: [
                "--object", "secret,id=sec_old,file=\(oldSecret.path)",
                "--object", "secret,id=sec_new,file=\(newSecret.path)",
                "-o", "encrypt.old-secret=sec_old,encrypt.state=inactive",
                "--image-opts",
                "driver=qcow2,file.filename=\(url.path),encrypt.key-secret=sec_new",
            ])
        } catch {
            // step 2 失败: 老 + 新都激活. 抛特殊错让用户重试.
            throw HVMError.encryption(.luksRekeyHalfDone(
                reason: "step 2 (remove old keyslot) 失败: \(error)"
            ))
        }
    }

    /// 探测 qcow2 是否 LUKS 加密. 走 qemu-img info, 不需 key (LUKS metadata 是明文).
    public static func isLuksEncrypted(at url: URL, qemuImg: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = ["info", "--output=json", "--force-share", url.path]
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return false }
        let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        // 简单识别: encrypted=true + format-specific.encrypt.format=luks
        // 完整 JSON 解析过度, 字符串包含识别已足够 (qemu-img info JSON 输出稳定).
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("\"encrypted\": true") && s.contains("\"format\": \"luks\"")
    }

    // MARK: - 内部 helper

    // SecretFile 已抽到 HVMEncryption/LuksSecretFile.swift (公共).

    /// 调 qemu-img. 失败抛 .qemuImgFailed.
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
