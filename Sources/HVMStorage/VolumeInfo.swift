// HVMStorage/VolumeInfo.swift
// 查询指定路径所在卷的剩余 / 总空间. 用于磁盘创建前预检

import Foundation
import HVMCore

public struct VolumeSpace: Sendable, Equatable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64
}

public enum VolumeInfo {
    /// 返回 path 所在卷的容量信息
    public static func space(at path: String) throws -> VolumeSpace {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        do {
            let values = try url.resourceValues(forKeys: keys)
            let total = UInt64(values.volumeTotalCapacity ?? 0)
            let avail = UInt64(values.volumeAvailableCapacityForImportantUsage
                               ?? Int64(values.volumeAvailableCapacity ?? 0))
            return VolumeSpace(totalBytes: total, availableBytes: avail)
        } catch {
            throw HVMError.storage(.ioError(errno: EIO, path: path))
        }
    }

    /// 预检创建/扩容磁盘, 若卷剩余空间小于 requiredBytes 抛错
    public static func assertSpaceAvailable(at path: String, requiredBytes: UInt64) throws {
        let s = try space(at: path)
        // raw sparse 只需要剩余空间能容纳一次性写入的估计值.
        // M1 保守估计 = 请求尺寸的 1% 或 至少 128 MiB, 保证创建时不会立即 ENOSPC.
        let threshold = max(requiredBytes / 100, UInt64(128) << 20)
        guard s.availableBytes >= threshold else {
            throw HVMError.storage(.volumeSpaceInsufficient(
                requiredBytes: threshold,
                availableBytes: s.availableBytes
            ))
        }
    }
}
