// HVMInstall/MacAuxiliaryFactory.swift
// 一次性生成 macOS guest 必需的 auxiliary 三件套.
//
// auxiliary/ 三件套:
//   - aux-storage          → VZMacAuxiliaryStorage 持久化文件 (firmware NVRAM)
//   - hardware-model       → VZMacHardwareModel.dataRepresentation, 一次性写, 不可变
//   - machine-identifier   → VZMacMachineIdentifier.dataRepresentation, 每 VM 唯一, 不可变
//
// 任一损坏整台 VM 报废. 启动期 (ConfigBuilder) 通过 HVMBackend.MacPlatform.load(from:)
// 读取这三个文件构造 VZMacPlatformConfiguration; 详见 docs/GUEST_OS_INSTALL.md.
//
// === 幂等性约束 ===
//
// 装机中途失败 (VZMacOSInstaller 抛错 / 进程崩) 时, hardware-model + machine-identifier 已落盘.
// 用户 retry 时:
//   - 若用同一 IPSW 重试 → 新计算出的 hardware-model 与盘上一致, 跳过写入, machine-identifier
//     保留 (不重生成), aux-storage allowOverwrite 重写 — 保持原 VM 身份, 安全
//   - 若用不同 IPSW 重试 → 新 hardware-model 与盘上不一致, 直接报错让用户先 rm bundle 再重建.
//     避免覆盖后破坏 hwModel + machineID 配对, 装出来的 VM 永远跑不起.
//
// 这个校验在 retry 场景下是 correctness-critical: hardware-model 与 machine-identifier 必须
// 始终来自同一次绑定, 不能跨 IPSW 串.

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum MacAuxiliaryFactory {
    /// 创建 auxiliary 三件套. 已存在但与新 IPSW 不匹配的 hardware-model 会触发报错.
    /// - Note: 调用方必须保证 bundle 没在跑 (BundleLock.isBusy=false), 否则 VZ 抢锁失败.
    public static func create(in bundleURL: URL, from handle: RestoreImageHandle) throws {
        guard let req = handle.image.mostFeaturefulSupportedConfiguration else {
            throw HVMError.install(.ipswUnsupported(reason: "no supported configuration"))
        }

        let auxDir = BundleLayout.auxiliaryDir(bundleURL)
        do {
            try FileManager.default.createDirectory(at: auxDir, withIntermediateDirectories: true)
        } catch {
            throw HVMError.install(.auxiliaryCreationFailed(reason: "mkdir auxiliary/: \(error)"))
        }

        let auxStorageURL = auxDir.appendingPathComponent(BundleLayout.auxStorageName)
        let machineIDURL  = auxDir.appendingPathComponent(BundleLayout.machineIdentifier)
        let hwModelURL    = auxDir.appendingPathComponent(BundleLayout.hardwareModel)

        // 1. hardware-model: 已存在则字节比对, 一致跳过 (幂等); 不一致直接报错保护 hwModel+machineID 配对
        let hwModel = req.hardwareModel
        let newHwData = hwModel.dataRepresentation
        if let existing = try? Data(contentsOf: hwModelURL) {
            if existing != newHwData {
                throw HVMError.install(.auxiliaryCreationFailed(reason: """
                    bundle 内已有 hardware-model 与本次 IPSW 不一致, 这通常意味着上次装机失败后用了不同的 IPSW 重试.
                    一旦覆盖会破坏 hardware-model 与 machine-identifier 的配对, 装出来的 VM 无法启动.
                    解决: 先删除整个 .hvmz bundle, 再用新 IPSW 重新创建.
                    """))
            }
            // 一致 → 跳过写入 (保持 atime / 减少 IO)
        } else {
            do {
                try newHwData.write(to: hwModelURL, options: .atomic)
            } catch {
                throw HVMError.install(.auxiliaryCreationFailed(reason: "hardware-model write: \(error)"))
            }
        }

        // 2. machine-identifier: 已存在保留 (与 hardware-model 配对, 不可改); 没有则生成新的
        if !FileManager.default.fileExists(atPath: machineIDURL.path) {
            let machineID = VZMacMachineIdentifier()
            do {
                try machineID.dataRepresentation.write(to: machineIDURL, options: .atomic)
            } catch {
                throw HVMError.install(.auxiliaryCreationFailed(reason: "machine-identifier write: \(error)"))
            }
        }

        // 3. VZMacAuxiliaryStorage 创建. allowOverwrite: retry 时旧 aux-storage 内容已无效, 让 VZ 重写.
        do {
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxStorageURL,
                hardwareModel: hwModel,
                options: [.allowOverwrite]
            )
        } catch {
            throw HVMError.install(.auxiliaryCreationFailed(reason: "aux-storage: \(error)"))
        }
    }
}
