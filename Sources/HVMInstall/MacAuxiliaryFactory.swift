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

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum MacAuxiliaryFactory {
    /// 创建 auxiliary 三件套. 已存在的会被覆盖 (.allowOverwrite).
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

        // 1. hardware-model 落盘 (从 IPSW req 拿来, 不可变)
        let hwModel = req.hardwareModel
        do {
            try hwModel.dataRepresentation.write(to: hwModelURL, options: .atomic)
        } catch {
            throw HVMError.install(.auxiliaryCreationFailed(reason: "hardware-model write: \(error)"))
        }

        // 2. machine-identifier 生成新的并落盘
        let machineID = VZMacMachineIdentifier()
        do {
            try machineID.dataRepresentation.write(to: machineIDURL, options: .atomic)
        } catch {
            throw HVMError.install(.auxiliaryCreationFailed(reason: "machine-identifier write: \(error)"))
        }

        // 3. VZMacAuxiliaryStorage 创建 (装机所需的存储, VZ 自己写)
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
