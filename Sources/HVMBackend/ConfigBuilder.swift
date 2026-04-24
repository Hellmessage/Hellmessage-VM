// HVMBackend/ConfigBuilder.swift
// 把 VMConfig 翻译为 VZVirtualMachineConfiguration. M1 仅 Linux 路径;
// macOS 路径随 M3 HVMInstall 一起落地. 详见 docs/VZ_BACKEND.md

import Foundation
@preconcurrency import Virtualization
import HVMBundle
import HVMCore
import HVMNet
import HVMStorage

public enum ConfigBuilder {
    public static func build(from config: VMConfig, bundleURL: URL) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()

        // CPU / 内存范围校验
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        guard (minCPU...maxCPU).contains(config.cpuCount) else {
            throw HVMError.backend(.cpuOutOfRange(requested: config.cpuCount, min: minCPU, max: maxCPU))
        }
        vz.cpuCount = config.cpuCount

        let minMemMiB = VZVirtualMachineConfiguration.minimumAllowedMemorySize / (1024 * 1024)
        let maxMemMiB = VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024)
        guard (minMemMiB...maxMemMiB).contains(config.memoryMiB) else {
            throw HVMError.backend(.memoryOutOfRange(
                requestedMiB: config.memoryMiB, minMiB: minMemMiB, maxMiB: maxMemMiB
            ))
        }
        vz.memorySize = config.memoryMiB * 1024 * 1024

        // Platform + BootLoader (仅 Linux)
        switch config.guestOS {
        case .macOS:
            throw HVMError.backend(.unsupportedGuestOS(raw: "macOS (M3 起支持)"))

        case .linux:
            vz.platform = VZGenericPlatformConfiguration()

            let nvramURL = BundleLayout.nvramURL(bundleURL)
            let variableStore: VZEFIVariableStore
            if FileManager.default.fileExists(atPath: nvramURL.path) {
                variableStore = VZEFIVariableStore(url: nvramURL)
            } else {
                try? FileManager.default.createDirectory(
                    at: nvramURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    variableStore = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL)
                } catch {
                    throw HVMError.backend(.vzInternal(description: "create EFI variable store: \(error)"))
                }
            }
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = variableStore
            vz.bootLoader = bootLoader
        }

        // 磁盘
        var storageDevices: [VZStorageDeviceConfiguration] = []
        for disk in config.disks {
            let diskURL = bundleURL.appendingPathComponent(disk.path)
            guard FileManager.default.fileExists(atPath: diskURL.path) else {
                throw HVMError.backend(.diskNotFound(path: diskURL.path))
            }
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: disk.readOnly)
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            } catch {
                throw HVMError.backend(.vzInternal(description: "disk attach \(diskURL.lastPathComponent): \(error)"))
            }
        }

        // ISO (仅 bootFromDiskOnly=false)
        if !config.bootFromDiskOnly, let isoPath = config.installerISO {
            do {
                try ISOValidator.validate(at: isoPath)
            } catch let e as HVMError {
                throw e
            } catch {
                throw HVMError.storage(.isoMissing(path: isoPath))
            }
            do {
                let isoURL = URL(fileURLWithPath: isoPath)
                let isoAttach = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
                storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttach))
            } catch {
                throw HVMError.backend(.vzInternal(description: "ISO attach: \(error)"))
            }
        }
        vz.storageDevices = storageDevices

        // 网卡
        vz.networkDevices = try config.networks.map { try NICFactory.make(spec: $0) }

        // 显示设备. Initial scanout 1024x768: 对 text-mode installer (fbcon 80x25) 字体占比友好.
        // 注意: Linux fbcon 不响应 virtio-gpu resize 事件, automaticallyReconfiguresDisplay
        // 仅在 guest 进入 X/Wayland 后才生效.
        let scanout = VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [scanout]
        vz.graphicsDevices = [graphics]

        // 输入设备
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // 熵源
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Virtio console (serial) -> bundle/run/console.sock, 供 hvm-dbg console 使用
        let runDir = bundleURL.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let serialSocket = BundleLayout.serialSocketURL(bundleURL)
        // 移除旧的 socket 残留 (上次进程崩溃留下)
        try? FileManager.default.removeItem(at: serialSocket)
        let consoleAttachment = try makeSerialAttachment(at: serialSocket)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = consoleAttachment
        vz.serialPorts = [serial]

        // 最终由 VZ 自校验
        do {
            try vz.validate()
        } catch {
            throw HVMError.backend(.configInvalid(field: "(vz.validate)", reason: "\(error)"))
        }

        return vz
    }

    /// 在 bundle/run/ 下创建 Unix domain socket, VZ serial 端挂上该 socket.
    /// 外部进程 (hvm-dbg, M5 再用) 可连接读写 guest serial.
    private static func makeSerialAttachment(at url: URL) throws -> VZVirtioConsoleDeviceSerialPortConfiguration.Attachment {
        // M1 简化: 用 /dev/null 作 stdio attach, 不实装 socket (避免阻塞 startup).
        // hvm-dbg console 在 M5 起实装时再切 socket.
        let nullHandle = FileHandle(forUpdatingAtPath: "/dev/null")
            ?? FileHandle.nullDevice
        return VZFileHandleSerialPortAttachment(fileHandleForReading: nullHandle,
                                                fileHandleForWriting: nullHandle)
    }
}

// VZVirtioConsoleDeviceSerialPortConfiguration.Attachment 的 type alias (VZ 命名较长)
extension VZVirtioConsoleDeviceSerialPortConfiguration {
    public typealias Attachment = VZSerialPortAttachment
}
