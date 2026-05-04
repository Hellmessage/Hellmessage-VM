// HVMEncryption/SecureErase.swift
// 单文件 best-effort secure delete: 覆写一遍 + unlink. 用于加密化转换时清旧明文文件
// (config.yaml / efi-vars.fd / 旧 raw disks / 旧 swtpm tpm/permall).
//
// 注意:
//   - APFS / SSD wear leveling 让真正的 secure-erase 不可靠
//   - 单 pass random 覆写仅"提高成本", 不能保证 100% 不可恢复
//   - 真正彻底防御靠 host FileVault 全盘加密 (HVM 不强制, 但 README / 文档强烈建议)
//
// 实现:
//   - open(O_WRONLY | O_TRUNC) — APFS sparse 文件 truncate 后 block 即被释放, 后续覆写
//     的是新 block 不是老 block. 因此先 read 老内容长度 → 覆写 → fsync → unlink.
//   - 用 random bytes 覆写 (从 SecRandomCopyBytes 拿). 单 pass 即可 (Schneier 7-pass 是
//     磁性介质时代过时建议, SSD 上 1 pass 与 7 pass 差不多)

import Foundation
import Darwin
import Security
import HVMCore

public enum SecureErase {
    private static let log = HVMLog.logger("encryption.secureErase")

    /// 对单文件执行 best-effort secure delete.
    /// 失败不抛 (best-effort 性质); 写诊断 log.
    public static func eraseFile(at url: URL) {
        let path = url.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        // 文件长度
        var st = stat()
        guard stat(path, &st) == 0 else {
            // stat 失败 → 直接 unlink
            _ = Darwin.unlink(path)
            return
        }
        let size = Int(st.st_size)

        // 不是普通文件 (符号链接 / 目录) 跳过
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.unlink(path)
            return
        }

        if size > 0 {
            // open + 覆写 random + fsync
            let fd = open(path, O_WRONLY)
            if fd >= 0 {
                defer { close(fd) }
                let chunkSize = min(64 * 1024, size)   // 64 KiB chunk
                var buf = Data(count: chunkSize)
                var written = 0
                while written < size {
                    let toWrite = min(chunkSize, size - written)
                    _ = buf.withUnsafeMutableBytes { rawPtr -> Int32 in
                        guard let base = rawPtr.baseAddress else { return -1 }
                        return Int32(SecRandomCopyBytes(kSecRandomDefault, toWrite, base))
                    }
                    let n = buf.withUnsafeBytes { rawPtr -> Int in
                        guard let base = rawPtr.baseAddress else { return -1 }
                        return write(fd, base, toWrite)
                    }
                    if n <= 0 { break }
                    written += n
                }
                _ = fsync(fd)
            } else {
                Self.log.warning("SecureErase: open(\(path, privacy: .public)) failed errno=\(errno)")
            }
        }

        _ = Darwin.unlink(path)
    }

    /// 对目录递归执行 secure delete (每个文件 erase 后 rmdir).
    public static func eraseDirectory(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if let entries = try? fm.contentsOfDirectory(atPath: url.path) {
            for n in entries {
                let entry = url.appendingPathComponent(n)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    eraseDirectory(at: entry)
                } else {
                    eraseFile(at: entry)
                }
            }
        }
        _ = Darwin.rmdir(url.path)
    }
}
