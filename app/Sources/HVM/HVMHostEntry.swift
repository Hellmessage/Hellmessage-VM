// HVMHostEntry.swift — VMHost 子进程入口 (`--host-mode-bundle`).
//
// QEMU-only 转向后 (docs/v4/QEMU_ONLY_PIVOT.md): VZ 后端整条移除. 本入口只做
// 加密检测 + 解锁 + 抢锁 等共用前置, 然后一律分派 QemuHostEntry (QEMU 子进程跑
// qemu-system-aarch64 + HDP IOSurface 显示). 老的 VZ 离屏 window / HVMView / HostState
// 已删. 明文/加密 (qemuPerfile) 都走 QEMU; vz / vz-sparsebundle 报错下线.

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMIPC

public enum HVMHostEntry {
    @MainActor
    public static func run(bundlePath: String,
                           password: String? = nil,
                           embeddedInGUI: Bool = false) -> Never {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        // 0. 加密形态检测 (不解密, 仅看 routing JSON / sparsebundle 后缀)
        let encryptionScheme = EncryptedBundleIO.detectScheme(at: bundleURL)

        // 1. 载入 config + 解锁 (按加密形态分流)
        let config: VMConfig
        let unlocked: EncryptedBundleIO.UnlockedHandle?

        switch encryptionScheme {
        case .none:
            // 明文 VM
            unlocked = nil
            do {
                config = try BundleIO.load(from: bundleURL)
            } catch {
                fputs("HVMHost: 加载 bundle 失败: \(error)\n", stderr)
                exit(3)
            }

        case .qemuPerfile:
            // 加密 QEMU VM: 必须有 password
            guard let pw = password, !pw.isEmpty else {
                fputs("HVMHost: 加密 VM 需要密码 (stdin 读到空); hvm-cli / GUI 应已 prompt\n", stderr)
                exit(40)
            }
            do {
                let handle = try EncryptedBundleIO.unlock(bundlePath: bundleURL, password: pw)
                unlocked = handle
                config = handle.config
            } catch let e as HVMError {
                fputs("HVMHost: 加密 VM 解锁失败: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
                if case .encryption(.wrongPassword) = e {
                    exit(41)   // 密码错
                }
                exit(42)
            } catch {
                fputs("HVMHost: 加密 VM 解锁失败: \(error)\n", stderr)
                exit(42)
            }
        }

        // 2. 抢锁 (共用前置)
        let socketURL = HVMPaths.socketPath(for: config.id)
        do {
            try HVMPaths.ensure(HVMPaths.runDir)
        } catch {
            fputs("HVMHost: 创建 run 目录失败: \(error)\n", stderr)
            try? unlocked?.close()
            exit(1)
        }

        let lock: BundleLock
        do {
            lock = try BundleLock(bundleURL: bundleURL, mode: .runtime, socketPath: socketURL.path)
        } catch let e as HVMError {
            fputs("HVMHost: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
            try? unlocked?.close()
            exit(4)
        } catch {
            fputs("HVMHost: 抢锁失败: \(error)\n", stderr)
            try? unlocked?.close()
            exit(4)
        }

        let startedAt = Date()

        // 3. 按 engine 分派. QEMU-only: 仅 .qemu 有实现, .vz 下线报错.
        // QEMU-only: Engine 单 case, 直接分派 QemuHostEntry
        QemuHostEntry.run(
            config: config, bundleURL: bundleURL,
            lock: lock, socketURL: socketURL, startedAt: startedAt,
            embeddedInGUI: embeddedInGUI,
            encryptedHandle: unlocked
        )
    }
}

/// 跨线程传递 IPCResponse 的可变容器 (Swift 6 sending 检查绕过). QemuHostEntry IPC 循环复用.
final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse
    init(_ v: IPCResponse) { self.value = v }
}
