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
    /// build 结果. consoleBridge 必须由 caller (VMHandle) 持有, 否则 fd 被回收会令 VZ 拿到失效 attachment.
    public struct BuildResult {
        public let vzConfig: VZVirtualMachineConfiguration
        public let consoleBridge: ConsoleBridge
    }

    public static func build(from config: VMConfig, bundleURL: URL) throws -> BuildResult {
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
                let attachment = try makeDiskAttachment(url: diskURL, readOnly: disk.readOnly, guestOS: config.guestOS)
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
                let isoAttach = try makeDiskAttachment(url: isoURL, readOnly: true, guestOS: config.guestOS)
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

        // Virtio console (serial): guest stdout (kernel + systemd + 早期登录前的输出)
        // 双向 pipe + tee 到 bundle/logs/console-YYYY-MM-DD.log, hvm-dbg console 子命令通过 bridge 读写.
        let bridge = try makeConsoleBridge(bundleURL: bundleURL)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: bridge.vzReadHandle,
            fileHandleForWriting: bridge.vzWriteHandle
        )
        vz.serialPorts = [serial]

        // 最终由 VZ 自校验
        do {
            try vz.validate()
        } catch {
            throw HVMError.backend(.configInvalid(field: "(vz.validate)", reason: "\(error)"))
        }

        return BuildResult(vzConfig: vz, consoleBridge: bridge)
    }

    /// 创建 VZ 磁盘 attachment. Linux guest 必须用 `cachingMode=.cached + synchronizationMode=.fsync`,
    /// 否则 VZ 默认 (.automatic) 在 Linux 上会触发 I/O error / 数据损坏 — UTM 长期踩坑后报告
    /// (https://github.com/utmapp/UTM/issues/4840), VirtualBuddy 也按这个模式. 装机阶段
    /// curtin extract / in-target 卡死的根因就是这个.
    /// macOS guest 不需要, 走 VZ 默认.
    private static func makeDiskAttachment(url: URL, readOnly: Bool, guestOS: GuestOSType) throws -> VZDiskImageStorageDeviceAttachment {
        switch guestOS {
        case .linux:
            return try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: readOnly,
                cachingMode: .cached, synchronizationMode: .fsync
            )
        case .macOS:
            return try VZDiskImageStorageDeviceAttachment(url: url, readOnly: readOnly)
        }
    }

    /// 创建 ConsoleBridge: 双向 pipe + 日志 tee + ring buffer.
    /// guest 输出 append 到 bundle/logs/console-<date>.log (Bridge 内部按天 rotate),
    /// hvm-dbg 走 bridge 读写. bridge 必须由 VMHandle 持有, 否则 fd lifecycle 失控.
    private static func makeConsoleBridge(bundleURL: URL) throws -> ConsoleBridge {
        return try ConsoleBridge(logsDir: BundleLayout.logsDir(bundleURL))
    }
}

// VZVirtioConsoleDeviceSerialPortConfiguration.Attachment 的 type alias (VZ 命名较长)
extension VZVirtioConsoleDeviceSerialPortConfiguration {
    public typealias Attachment = VZSerialPortAttachment
}
