// HVMStorage/DiskFactory.swift
// raw sparse 磁盘文件的创建 / 扩容 / 删除, 依赖 APFS sparse 语义
// 详见 docs/STORAGE.md

import Foundation
import Darwin
import HVMCore

public enum DiskFactory {
    private static let log = HVMLog.logger("storage.disk")

    /// 创建 sizeGiB 大小的 raw sparse 文件. ftruncate 不实际分配块, 文件一开始物理占用 0.
    /// - Throws: HVMError.storage.diskAlreadyExists / .creationFailed
    public static func create(at url: URL, sizeGiB: UInt64) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw HVMError.storage(.diskAlreadyExists(path: url.path))
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            throw HVMError.storage(.creationFailed(errno: errno, path: url.path))
        }
        defer { close(fd) }
        let bytes = off_t(sizeGiB) * 1024 * 1024 * 1024
        guard ftruncate(fd, bytes) == 0 else {
            let saved = errno
            try? FileManager.default.removeItem(at: url)
            throw HVMError.storage(.creationFailed(errno: saved, path: url.path))
        }
        Self.log.info("disk created: \(url.lastPathComponent, privacy: .public) sizeGiB=\(sizeGiB)")
    }

    /// 扩容到新大小 (GiB). 只支持增大, 缩小直接抛 .shrinkNotSupported.
    public static func grow(at url: URL, toGiB: UInt64) throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        let oldBytes = Int64(st.st_size)
        let newBytes = Int64(toGiB) * 1024 * 1024 * 1024
        guard newBytes > oldBytes else {
            throw HVMError.storage(.shrinkNotSupported(currentBytes: oldBytes, requestedBytes: newBytes))
        }
        guard ftruncate(fd, off_t(newBytes)) == 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        Self.log.info("disk grown: \(url.lastPathComponent, privacy: .public) \(oldBytes)B → \(newBytes)B")
    }

    public static func delete(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HVMError.storage(.ioError(errno: EIO, path: url.path))
        }
        Self.log.info("disk deleted: \(url.lastPathComponent, privacy: .public)")
    }

    /// 逻辑大小 (stat.st_size)
    public static func logicalBytes(at url: URL) throws -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        return UInt64(st.st_size)
    }

    /// 实际物理占用 (stat.st_blocks * 512). APFS sparse 文件会显著小于逻辑
    public static func actualBytes(at url: URL) throws -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        return UInt64(st.st_blocks) * 512
    }

    /// 对数据盘生成 uuid 前 8 位 (小写 hex)
    public static func newDataDiskUUID8() -> String {
        UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
    }
}
