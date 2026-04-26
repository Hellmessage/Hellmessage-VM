// HVMStorage/DiskFactory.swift
// 磁盘文件创建 / 扩容 / 删除. 入口接收 DiskFormat 参数显式分流, 不再推断扩展名.
//   - .raw   → ftruncate sparse (依赖 APFS sparse, VZ 后端必走)
//   - .qcow2 → qemu-img create / resize (QEMU 后端走, 必传 qemuImg URL)
// VZ 后端: VZDiskImageStorageDeviceAttachment 只接受 raw, 强约束.
// QEMU 后端: 新建走 qcow2; 老 VM 已是 raw 仍可继续运行 (DiskSpec.format 持久化在 config).
//
// 详见 docs/STORAGE.md + CLAUDE.md "磁盘与存储约束".

import Foundation
import Darwin
import HVMCore
import HVMBundle

public enum DiskFactory {
    private static let log = HVMLog.logger("storage.disk")

    /// 创建磁盘. format 决定走 raw 还是 qcow2 路径; qcow2 必须传 qemuImg.
    /// - Throws: HVMError.storage.diskAlreadyExists / .creationFailed
    public static func create(at url: URL, sizeGiB: UInt64, format: DiskFormat, qemuImg: URL? = nil) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw HVMError.storage(.diskAlreadyExists(path: url.path))
        }
        switch format {
        case .raw:
            try createRaw(at: url, sizeGiB: sizeGiB)
        case .qcow2:
            guard let qemuImg else {
                throw HVMError.storage(.creationFailed(errno: ENOENT, path: url.path))
            }
            try createQcow2(at: url, sizeGiB: sizeGiB, qemuImg: qemuImg)
        }
        Self.log.info("disk created: \(url.lastPathComponent, privacy: .public) sizeGiB=\(sizeGiB) format=\(format.rawValue, privacy: .public)")
    }

    /// 扩容磁盘 (只能增大). format 决定走 ftruncate 还是 qemu-img resize.
    public static func grow(at url: URL, toGiB: UInt64, format: DiskFormat, qemuImg: URL? = nil) throws {
        switch format {
        case .raw:
            try growRaw(at: url, toGiB: toGiB)
        case .qcow2:
            guard let qemuImg else {
                throw HVMError.storage(.ioError(errno: ENOENT, path: url.path))
            }
            try growQcow2(at: url, toGiB: toGiB, qemuImg: qemuImg)
        }
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

    /// 逻辑大小 (stat.st_size). raw 即名义大小; qcow2 是文件本身字节数, 非 guest 看到的虚拟容量.
    public static func logicalBytes(at url: URL) throws -> UInt64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw HVMError.storage(.ioError(errno: errno, path: url.path))
        }
        return UInt64(st.st_size)
    }

    /// 实际物理占用 (stat.st_blocks * 512). raw sparse 显著小于逻辑; qcow2 等价于文件大小.
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

    // MARK: - raw (ftruncate)

    private static func createRaw(at url: URL, sizeGiB: UInt64) throws {
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
    }

    private static func growRaw(at url: URL, toGiB: UInt64) throws {
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
        Self.log.info("disk grown (raw): \(url.lastPathComponent, privacy: .public) \(oldBytes)B → \(newBytes)B")
    }

    // MARK: - qcow2 (qemu-img)

    private static func createQcow2(at url: URL, sizeGiB: UInt64, qemuImg: URL) throws {
        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = ["create", "-f", "qcow2", url.path, "\(sizeGiB)G"]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            throw HVMError.storage(.creationFailed(errno: EIO, path: url.path))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let stderr = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Self.log.error("qemu-img create 失败 status=\(proc.terminationStatus) stderr=\(stderr, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            throw HVMError.storage(.creationFailed(errno: EIO, path: url.path))
        }
    }

    private static func growQcow2(at url: URL, toGiB: UInt64, qemuImg: URL) throws {
        let proc = Process()
        proc.executableURL = qemuImg
        proc.arguments = ["resize", url.path, "\(toGiB)G"]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            throw HVMError.storage(.ioError(errno: EIO, path: url.path))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let stderr = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Self.log.error("qemu-img resize 失败 status=\(proc.terminationStatus) stderr=\(stderr, privacy: .public)")
            throw HVMError.storage(.ioError(errno: EIO, path: url.path))
        }
        Self.log.info("disk grown (qcow2): \(url.lastPathComponent, privacy: .public) → \(toGiB)GiB")
    }
}
