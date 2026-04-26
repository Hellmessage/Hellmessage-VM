// HVMBackend/MacPlatform.swift
// 从 bundle 读 auxiliary 三件套, 装配 VZMacPlatformConfiguration. 给 ConfigBuilder 的 macOS 分支用.
//
// 创建 (装机时一次性) 的对偶函数在 HVMInstall.MacAuxiliaryFactory.create.
// 读取阶段不依赖 IPSW, 单纯解析 bundle/auxiliary/ 下的三个文件.

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore

public enum MacPlatform {
    /// 从已装好的 bundle 读 platform 配置, 给 VZVirtualMachineConfiguration.platform 用.
    /// 三件套任一缺失/损坏 → 抛 .bundle(.corruptAuxiliary).
    public static func load(from bundleURL: URL) throws -> VZMacPlatformConfiguration {
        let auxDir = BundleLayout.auxiliaryDir(bundleURL)
        let auxStorageURL = auxDir.appendingPathComponent(BundleLayout.auxStorageName)
        let machineIDURL  = auxDir.appendingPathComponent(BundleLayout.machineIdentifier)
        let hwModelURL    = auxDir.appendingPathComponent(BundleLayout.hardwareModel)

        guard let hwData = try? Data(contentsOf: hwModelURL) else {
            throw HVMError.bundle(.corruptAuxiliary(reason: "hardware-model 文件缺失"))
        }
        guard let hwModel = VZMacHardwareModel(dataRepresentation: hwData) else {
            throw HVMError.bundle(.corruptAuxiliary(reason: "hardware-model 解析失败"))
        }
        guard hwModel.isSupported else {
            throw HVMError.bundle(.corruptAuxiliary(
                reason: "hardware-model 当前 VZ 不支持 (可能 IPSW 与本机硬件不匹配)"
            ))
        }

        guard let mIDData = try? Data(contentsOf: machineIDURL) else {
            throw HVMError.bundle(.corruptAuxiliary(reason: "machine-identifier 文件缺失"))
        }
        guard let machineID = VZMacMachineIdentifier(dataRepresentation: mIDData) else {
            throw HVMError.bundle(.corruptAuxiliary(reason: "machine-identifier 解析失败"))
        }

        // aux-storage 仅校验存在, VZMacAuxiliaryStorage(url:) 是用文件路径起 VZ 句柄, 不返回 throws.
        guard FileManager.default.fileExists(atPath: auxStorageURL.path) else {
            throw HVMError.bundle(.corruptAuxiliary(reason: "aux-storage 文件缺失 (装机未完成?)"))
        }
        let auxStorage = VZMacAuxiliaryStorage(url: auxStorageURL)

        let platform = VZMacPlatformConfiguration()
        platform.auxiliaryStorage = auxStorage
        platform.hardwareModel = hwModel
        platform.machineIdentifier = machineID
        return platform
    }
}
