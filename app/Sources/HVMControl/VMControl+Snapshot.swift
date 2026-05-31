// VMControl+Snapshot.swift — VM 快照 (CLI + GUI 共用门面). 底层 SnapshotManager (APFS clonefile).
// create/restore 必须 stopped (盘在写则快照不一致); list/delete 不要求.

import Foundation
import HVMCore
import HVMStorage

public extension VMControl {
    /// 创建快照 (clonefile, 秒级). 必须 stopped.
    static func createSnapshot(bundleURL: URL, name: String) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        try SnapshotManager.create(bundleURL: bundleURL, name: name)
    }

    /// 列快照 (createdAt 倒序). 无副作用, 不要求 stopped.
    static func listSnapshots(bundleURL: URL) -> [SnapshotManager.Info] {
        SnapshotManager.list(bundleURL: bundleURL)
    }

    /// 恢复快照 (覆盖当前 disks + config + nvram/tpm). 必须 stopped. 破坏性 — 调用方先确认.
    static func restoreSnapshot(bundleURL: URL, name: String) throws {
        try assertStoppedIfNeeded(bundleURL: bundleURL, requireStopped: true)
        try SnapshotManager.restore(bundleURL: bundleURL, name: name)
    }

    /// 删快照. 不要求 stopped (只删 snapshots/<name>/, 不动当前 VM).
    static func deleteSnapshot(bundleURL: URL, name: String) throws {
        try SnapshotManager.delete(bundleURL: bundleURL, name: name)
    }
}
