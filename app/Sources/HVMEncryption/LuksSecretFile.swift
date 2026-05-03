// HVMEncryption/LuksSecretFile.swift
// 给 qemu-img / qemu-system 注入 LUKS passphrase 的临时文件包装.
//
// 关键约束: LUKS spec 要求 passphrase 是 UTF-8 合法字符串. 我们的 sub key 是 32 字节 binary
// (PBKDF2 / HKDF 输出, 大概率含非 UTF-8 字节如 0x80-0xBF / 0xFE / 0xFF). 直接写 raw bytes
// 给 qemu-img 会报 "Data from secret sec0 is not valid UTF-8".
//
// 解决: 把 32 字节 binary 走 base64 编码成 ASCII 字符串 (44 字符), 写入 secret file.
// LUKS 把 ASCII base64 字符串当 passphrase 走自家 PBKDF2 派生 LUKS master key.
// 跨机器一致性: 同 32 字节 binary → 同 base64 字符串 → 同 LUKS passphrase → 同样解.
//
// 安全注:
//   - 文件 0o600 + open(O_CREAT|O_EXCL) 避免 race
//   - defer { secret.cleanup() } 立即 unlink
//   - NSTemporaryDirectory 是用户自家 /var/folders/... (默认 0o700), 跨用户不可读
//
// 不做:
//   - mlock 防交换 (Swift 暂不暴露干净 API; 留 PR 后续优化)
//   - secure-erase memset_s (写完即关 fd, ARC 释放 buffer; OS 重用前不主动清)
//
// 使用模式:
//   let secret = try LuksSecretFile(key: subKey)
//   defer { secret.cleanup() }
//   try qemu-img ... --object secret,id=sec0,file=\(secret.path)

import Foundation
import CryptoKit
import HVMCore

public struct LuksSecretFile: Sendable {
    /// 0o600 临时文件路径 (NSTemporaryDirectory 下 hvm-luks-<random>.txt). qemu-img / qemu-system
    /// 通过 --object secret,file= 传入此路径.
    public let path: String

    /// 把 32 字节 binary key 转 base64 ASCII 字符串, 写入新建 0o600 文件. 调用方负责 cleanup().
    public init(key: SymmetricKey) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hvm-luks-\(UUID().uuidString.prefix(12)).txt")
        self.path = url.path

        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw HVMError.encryption(.qemuImgFailed(
                verb: "luks-secret-prep",
                exitCode: Int32(errno),
                stderr: "无法创建 secret 临时文件: errno=\(errno)"
            ))
        }
        defer { close(fd) }

        // 32 字节 binary → base64 ASCII string. LUKS 把字符串当 passphrase, 字符串本身合法 UTF-8.
        let rawBytes = key.withUnsafeBytes { Data($0) }
        let b64 = rawBytes.base64EncodedString()
        guard let payload = b64.data(using: .utf8) else {
            Darwin.unlink(path)
            throw HVMError.encryption(.qemuImgFailed(
                verb: "luks-secret-prep", exitCode: -1,
                stderr: "base64 → utf8 编码失败"
            ))
        }
        let written = payload.withUnsafeBytes { rawPtr -> Int in
            guard let base = rawPtr.baseAddress else { return -1 }
            return write(fd, base, rawPtr.count)
        }
        guard written == payload.count else {
            Darwin.unlink(path)
            throw HVMError.encryption(.qemuImgFailed(
                verb: "luks-secret-prep", exitCode: -1,
                stderr: "写 secret 文件不完整: written=\(written), expected=\(payload.count)"
            ))
        }
    }

    /// 删除临时文件. 失败不抛 (qemu 进程可能已读完 + 删了; 或外部清).
    public func cleanup() {
        _ = Darwin.unlink(path)
    }
}
