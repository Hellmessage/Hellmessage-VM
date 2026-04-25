// HVMBackend/ConfigBuilder.swift
// 把 VMConfig 翻译为 VZVirtualMachineConfiguration.
// macOS 分支读 auxiliary/ 装配 VZMacPlatformConfiguration; Linux 分支走 EFI + ISO.
// 详见 docs/VZ_BACKEND.md

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

        // Platform + BootLoader + 输入/图形设备: 随 guestOS 分支
        switch config.guestOS {
        case .macOS:
            // Platform 从 bundle/auxiliary/ 读三件套 (装机阶段已落盘)
            vz.platform = try MacPlatform.load(from: bundleURL)
            vz.bootLoader = VZMacOSBootLoader()

            // 图形: VZMacGraphicsDevice + 1080p @ 220ppi (与 MacBook Pro Retina 一致)
            // 多显示器留给后续, M3 单屏
            let display = VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 220
            )
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [display]
            vz.graphicsDevices = [graphics]

            // 键盘: macOS 14+ 原生 keyboard, 比 USB 键盘转换损失小, 支持 Fn/media/Spotlight
            vz.keyboards = [VZMacKeyboardConfiguration()]

            // 指点: Mac Trackpad 支持手势 + USB 兜底绝对坐标
            vz.pointingDevices = [
                VZMacTrackpadConfiguration(),
                VZUSBScreenCoordinatePointingDeviceConfiguration(),
            ]

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

            // 图形: virtio scanout. 1024x768 对 fbcon 80x25 字体占比友好.
            // automaticallyReconfiguresDisplay 在 fbcon 阶段无效, guest 进 X/Wayland 后才生效.
            let scanout = VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [scanout]
            vz.graphicsDevices = [graphics]

            // Linux: USB 键盘 + USB 绝对坐标鼠标 (no Mac trackpad)
            vz.keyboards = [VZUSBKeyboardConfiguration()]
            vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
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

        // ISO 装机 (仅 Linux + bootFromDiskOnly=false). macOS 走 IPSW + VZMacOSInstaller, 不挂 ISO.
        if config.guestOS == .linux, !config.bootFromDiskOnly, let isoPath = config.installerISO {
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

        // 网卡 (公共)
        vz.networkDevices = try config.networks.map { try NICFactory.make(spec: $0) }

        // 熵源 (公共)
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
