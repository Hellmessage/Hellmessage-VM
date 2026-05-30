// VMCatalog.swift
// VM 枚举 — 收口 hvm-cli ListCommand.renderOnce + 老 AppModel.refreshList 两份扫盘逻辑.
//
// 加密 VM 不解密 (走 RoutingJSON 拿基础信息); 明文走 BundleIO.load.
// 运行态走 BundleLock.isBusy (flock 非阻塞探测). 返回按 displayName 升序.

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

public enum VMCatalog {
    /// 扫 root (默认 HVMPaths.vmsRoot) 下所有 .hvmz, 返回 summary 列表 (displayName 升序).
    /// 单个 bundle 读失败 (config 损坏 / routing 缺失) 跳过该 bundle, 不中断整体枚举.
    public static func list(in root: URL = HVMPaths.vmsRoot) -> [VMSummary] {
        let bundles = (try? BundleDiscovery.list(in: root)) ?? []
        var out: [VMSummary] = []
        for b in bundles {
            if let s = summary(for: b) { out.append(s) }
        }
        return out.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// 单个 bundle → summary. 读失败返 nil (UI/CLI 自行跳过).
    public static func summary(for bundleURL: URL) -> VMSummary? {
        let runState: RunState = BundleLock.isBusy(bundleURL: bundleURL) ? .running : .stopped

        // 加密 VM: 无明文 config.yaml, 走 routing JSON 拿 vmId / displayName / guestOS / scheme.
        if EncryptedBundleIO.detectScheme(at: bundleURL) != nil {
            // QEMU-only: 加密 VM 恒 qemu-perfile
            let routingURL = RoutingJSON.locationForQemuBundle(bundleURL)
            guard let routing = try? RoutingJSON.read(from: routingURL) else { return nil }
            // QEMU-only: 加密 VM 恒 qemu (vz-sparsebundle 已随 VZ 移除)
            let engine: Engine = .qemu
            return VMSummary(
                id: routing.vmId,
                bundleURL: bundleURL,
                displayName: routing.displayName,
                guestOS: routing.guestOS ?? .linux,   // v2 routing 无 guestOS, 兜底 linux
                engine: engine,
                runState: runState,
                encryptionScheme: .qemuPerfile,
                config: nil,
                cpuCount: nil,
                memoryMiB: nil,
                mainDiskLogicalGiB: nil
            )
        }

        // 明文 VM
        guard let config = try? BundleIO.load(from: bundleURL) else { return nil }
        return VMSummary(
            id: config.id,
            bundleURL: bundleURL,
            displayName: config.displayName,
            guestOS: config.guestOS,
            engine: config.engine,
            runState: runState,
            encryptionScheme: nil,
            config: config,
            cpuCount: config.cpuCount,
            memoryMiB: config.memoryMiB,
            mainDiskLogicalGiB: config.disks.first?.sizeGiB
        )
    }
}
