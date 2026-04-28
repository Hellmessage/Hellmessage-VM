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

    // MARK: - 导入外部磁盘镜像 (OpenWrt / Debian cloud image / Alpine 等预装好的 qcow2/raw)

    /// 导入磁盘镜像的元信息. virtualSizeBytes = guest 看到的容量, 不是文件本身字节.
    public struct ImportableDiskInfo: Sendable, Equatable {
        public let format: DiskFormat
        public let virtualSizeBytes: UInt64
        public init(format: DiskFormat, virtualSizeBytes: UInt64) {
            self.format = format
            self.virtualSizeBytes = virtualSizeBytes
        }
        /// 向上取整到 GiB (DiskSpec.sizeGiB 用 UInt64 GiB 单位).
        public var virtualSizeGiB: UInt64 {
            let gib: UInt64 = 1 << 30
            return (virtualSizeBytes + gib - 1) / gib
        }
    }

    /// 主盘容量上限 (GiB), 与 GUI stepper 上限对齐.
    public static let importMaxSizeGiB: UInt64 = 2048

    /// 探测外部镜像的格式与虚拟容量, 仅放行 qcow2 / raw, 其他 (vmdk/vhdx/...) 拒绝.
    /// 走 `qemu-img info --output=json`, 因此 qemuImg 必传 (QEMU 后端就绪是导入前提).
    public static func inspectImage(at url: URL, qemuImg: URL) throws -> ImportableDiskInfo {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw HVMError.storage(.importInvalid(reason: "文件不存在", path: path))
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw HVMError.storage(.importInvalid(reason: "文件不可读 (权限问题)", path: path))
        }

        let proc = Process()
        proc.executableURL = qemuImg
        // --force-share 防止用户的 qcow2 被别处独占 lock 导致 info 失败
        proc.arguments = ["info", "--output=json", "--force-share", path]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do { try proc.run() } catch {
            throw HVMError.storage(.importInvalid(reason: "qemu-img 启动失败: \(error)", path: path))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = (try? stderr.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw HVMError.storage(.importInvalid(
                reason: "qemu-img info 失败 (status=\(proc.terminationStatus)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))",
                path: path
            ))
        }
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        struct Info: Decodable {
            let format: String
            let virtualSize: UInt64
            enum CodingKeys: String, CodingKey {
                case format
                case virtualSize = "virtual-size"
            }
        }
        let info: Info
        do {
            info = try JSONDecoder().decode(Info.self, from: data)
        } catch {
            throw HVMError.storage(.importInvalid(reason: "qemu-img info JSON 解析失败: \(error)", path: path))
        }

        let format: DiskFormat
        switch info.format.lowercased() {
        case "qcow2": format = .qcow2
        case "raw":   format = .raw
        default:
            throw HVMError.storage(.importInvalid(
                reason: "镜像格式 \(info.format) 不支持, 仅接受 qcow2 / raw",
                path: path
            ))
        }

        // 防呆: 导入容量超过主盘上限 (GUI stepper 顶 2048 GiB)
        let maxBytes = importMaxSizeGiB * (1 << 30)
        if info.virtualSize > maxBytes {
            throw HVMError.storage(.importInvalid(
                reason: "镜像虚拟容量 \(info.virtualSize) bytes 超过上限 \(importMaxSizeGiB) GiB",
                path: path
            ))
        }
        if info.virtualSize == 0 {
            throw HVMError.storage(.importInvalid(reason: "镜像虚拟容量为 0", path: path))
        }
        return ImportableDiskInfo(format: format, virtualSizeBytes: info.virtualSize)
    }

    /// 把外部镜像拷贝到 bundle 的目标路径; 若 targetSizeGiB > 镜像 virtual-size 则拷贝后 resize.
    /// targetSizeGiB == nil 时按镜像 virtual-size 不变. targetSizeGiB < virtual-size 直接拒绝 (缩容不支持).
    /// qemuImg 仅在 resize 时用到; 不 resize 时可不传.
    public static func importImage(
        from src: URL,
        to dst: URL,
        info: ImportableDiskInfo,
        targetSizeGiB: UInt64?,
        qemuImg: URL?
    ) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            throw HVMError.storage(.diskAlreadyExists(path: dst.path))
        }
        // 缩容防呆: target 不可小于镜像本身的 virtual-size
        if let target = targetSizeGiB {
            let targetBytes = Int64(target) * 1024 * 1024 * 1024
            if targetBytes < Int64(info.virtualSizeBytes) {
                throw HVMError.storage(.shrinkNotSupported(
                    currentBytes: Int64(info.virtualSizeBytes),
                    requestedBytes: targetBytes
                ))
            }
            if target > importMaxSizeGiB {
                throw HVMError.storage(.importInvalid(
                    reason: "目标容量 \(target) GiB 超过上限 \(importMaxSizeGiB) GiB",
                    path: dst.path
                ))
            }
        }

        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw HVMError.storage(.creationFailed(errno: EIO, path: dst.path))
        }

        // 仅在显式放大时才调 qemu-img resize (raw 走 ftruncate, qcow2 走 qemu-img)
        if let target = targetSizeGiB,
           UInt64(Int64(target) * 1024 * 1024 * 1024) > info.virtualSizeBytes {
            do {
                try grow(at: dst, toGiB: target, format: info.format, qemuImg: qemuImg)
            } catch {
                // resize 失败回滚拷贝, 避免留下"半成品"主盘
                try? FileManager.default.removeItem(at: dst)
                throw error
            }
        }
        Self.log.info("disk imported: \(src.lastPathComponent, privacy: .public) → \(dst.lastPathComponent, privacy: .public) format=\(info.format.rawValue, privacy: .public) virtualGiB=\(info.virtualSizeGiB)")
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
