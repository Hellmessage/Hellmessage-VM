// HVMEncryption/MountReaper.swift
// 加密 VM (VZ 路径) 的 stale sparsebundle 挂载清理. 设计稿 docs/v3/ENCRYPTION.md v2.3.
//
// 触发场景:
//   - host crash / panic / kill -9 → VMHost 子进程死, sparsebundle 没 detach 留下挂载
//   - 主 HVM app / hvm-cli 启动期, 应一次性 reap 后再让用户启动新 VM
//
// 算法:
//   1. SparsebundleTool.info() 列所有当前 attach 的 disk image
//   2. 过滤 HVM 自家 sparsebundle (路径前缀 vmsRoot, 后缀 .hvmz.sparsebundle)
//   3. 对每个有 mountpoint 的:
//      a. 找 mountpoint 内 .hvmz 子目录的 .lock
//      b. BundleLock.isBusy 探测 (LOCK_EX|LOCK_NB) — 别的进程持着会失败
//      c. 不被持 → 视为 stale → SparsebundleTool.detach(force: true)
//      d. 被持 → 跳过 (活 VMHost 持有)
//
// 不做:
//   - 删除 sparsebundle 文件本身 (永远不动用户数据)
//   - 跨用户 reap (kSecAttrAccessibleWhenUnlockedThisDeviceOnly 等价语义)
//   - 强杀活 VMHost 子进程 (上层 lifecycle 管, 这里只 reap 已死的留下来的)
//
// QEMU 路径不需要 reap:
//   - swtpm-key 走 Pipe 不落盘 (PR-6)
//   - qemu-img / qemu-system 启动期 LuksSecretFile 走 NSTemporaryDirectory + defer cleanup,
//     系统重启会清; 主进程崩 + 子进程仍跑场景 LuksSecretFile 已经 unlink, 不留残留.

import Foundation
import HVMCore
import HVMBundle

public enum MountReaper {
    private static let log = HVMLog.logger("encryption.reaper")

    /// reap 结果统计.
    public struct ReapStats: Sendable, Equatable {
        /// 强制 detach 成功的 sparsebundle 路径
        public var detached: [String]
        /// 被识别为 stale 但 detach 失败 (上层应告警 + 写 host log)
        public var failed: [String]
        /// 被活 VM 持有跳过 (正常状态, 不是错误)
        public var skipped: [String]

        public init(detached: [String] = [],
                    failed: [String] = [],
                    skipped: [String] = []) {
            self.detached = detached
            self.failed = failed
            self.skipped = skipped
        }
    }

    /// 扫所有 HVM 自家 sparsebundle 挂载, 对没活 VM 持有的 force detach.
    /// 默认参数: hvmVmsRoot = HVMPaths.vmsRoot.
    public static func reapStaleMounts(hvmVmsRoot: URL = HVMPaths.vmsRoot) -> ReapStats {
        var stats = ReapStats()

        let entries: [SparsebundleTool.InfoEntry]
        do {
            entries = try SparsebundleTool.info()
        } catch {
            Self.log.error("MountReaper: SparsebundleTool.info 失败: \(String(describing: error), privacy: .public)")
            return stats
        }

        let normalizedRoot = hvmVmsRoot.standardizedFileURL.path

        for entry in entries {
            let imagePath = URL(fileURLWithPath: entry.imagePath).standardizedFileURL.path

            // 1. 仅 reap HVM 自家 sparsebundle (路径前缀 vmsRoot, 后缀 .hvmz.sparsebundle)
            //    路径前缀确保不动 hell-vm / lima / colima / 用户其他工具的 sparsebundle.
            guard imagePath.hasPrefix(normalizedRoot) else { continue }
            guard imagePath.hasSuffix(".hvmz.sparsebundle") else { continue }

            // 2. 没 mountpoint 不需要 reap (attach 但 -nomount 模式; HVM 不用)
            guard let mp = entry.mountpoint, !mp.isEmpty else {
                continue
            }

            let mountURL = URL(fileURLWithPath: mp)

            // 3. 看 mountpoint 内 .hvmz/.lock 是否被活进程持有
            if isAnyHvmzLockBusy(at: mountURL) {
                stats.skipped.append(imagePath)
                Self.log.info("MountReaper: skip (busy) \(imagePath, privacy: .public)")
                continue
            }

            // 4. 没人持 → stale, force detach
            do {
                try SparsebundleTool.detach(mountpoint: mountURL, force: true)
                stats.detached.append(imagePath)
                Self.log.warning("MountReaper: stale detach \(imagePath, privacy: .public) ← \(mp, privacy: .public)")
            } catch {
                stats.failed.append(imagePath)
                Self.log.error("MountReaper: stale detach 失败 \(imagePath, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        return stats
    }

    // MARK: - 内部

    /// 扫 mountpoint 一层下面的 .hvmz 子目录, 任一 .lock 被持有就视为活 VM.
    /// 走 BundleLock.isBusy (LOCK_EX|LOCK_NB) — 跨进程探测安全.
    private static func isAnyHvmzLockBusy(at mountURL: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: mountURL.path) else {
            return false
        }
        for name in entries where name.hasSuffix(".hvmz") {
            let bundleURL = mountURL.appendingPathComponent(name, isDirectory: true)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                return true
            }
        }
        return false
    }
}
