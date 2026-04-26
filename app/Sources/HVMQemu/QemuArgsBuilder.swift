// HVMQemu/QemuArgsBuilder.swift
// 纯函数: VMConfig + bundleURL + 路径 → qemu-system-aarch64 的 argv.
//
// 设计要点:
//   - 不做 IO (磁盘/ISO 存在性), 那是 BundleIO/StorageValidator 的责任
//   - VMConfig.validate() 已校验 engine ↔ guestOS 组合, 这里再 trust-but-verify
//   - 显式的 -drive 写法 (file=...,if=virtio,format=raw,cache=none), 不依赖 QEMU 自动设备类
//   - HVF 加速 + cpu host: Apple Silicon + AArch64 guest 标配, 不允许 fallback 到 TCG
//   - QMP socket: unix domain (server=on,wait=off), 严禁 TCP (CLAUDE.md QEMU 后端约束)
//
// 输出顺序固定 (便于测试 + 排错), 不尝试折叠成 -drive if=virtio 简写.

import Foundation
import HVMBundle
import HVMCore

public enum QemuArgsBuilder {

    /// argv 构造的所有输入, 显式注入便于测试
    public struct Inputs: Sendable {
        public let config: VMConfig
        /// .hvmz bundle 根目录 (磁盘 / nvram / run socket 都基于此)
        public let bundleURL: URL
        /// QemuPaths.resolveRoot() 的结果, 注入避免在 builder 里碰文件系统
        public let qemuRoot: URL
        /// QMP 控制 socket 的 host 侧绝对路径 (typical: ~/Library/Application Support/HVM/run/<vm-id>.qmp)
        public let qmpSocketPath: String
        /// virtio-win.iso 全局缓存绝对路径 (仅 windows guest 用; 由 VirtioWinCache 提供).
        /// 非 windows 或路径 nil 时不挂第二 cdrom.
        public let virtioWinISOPath: String?

        public init(
            config: VMConfig,
            bundleURL: URL,
            qemuRoot: URL,
            qmpSocketPath: String,
            virtioWinISOPath: String? = nil
        ) {
            self.config = config
            self.bundleURL = bundleURL
            self.qemuRoot = qemuRoot
            self.qmpSocketPath = qmpSocketPath
            self.virtioWinISOPath = virtioWinISOPath
        }
    }

    /// 构造 argv. 调用方负责把 [String] 喂给 Process.arguments.
    public static func build(_ inputs: Inputs) throws -> [String] {
        let cfg = inputs.config

        // 防御: VZ-only guest 不该到这里. validate() 应在调用前已拦截
        if cfg.guestOS == .macOS {
            throw HVMError.backend(.unsupportedGuestOS(
                raw: "macOS via QEMU (VZ-only guest reached QEMU args builder)"
            ))
        }

        var args: [String] = []

        // ---- 机器 + CPU + 加速器 ----
        // virt: aarch64 标准虚拟机型; gic-version=3 给现代 ARM Linux/Win 用
        args += ["-machine", "virt,gic-version=3"]
        // host: 透传 CPU 特性, HVF 必须用 host
        args += ["-cpu", "host"]
        // hvf: Apple Hypervisor.framework, 不允许 fallback (CLAUDE.md 约束)
        args += ["-accel", "hvf"]

        // ---- 资源 ----
        args += ["-smp", "\(cfg.cpuCount)"]
        args += ["-m", "\(cfg.memoryMiB)M"]
        args += ["-name", cfg.displayName]

        // 不让 QEMU 收到 ACPI reboot 后自旋重启 — system_reset 直接 exit, 与 hvm-cli 语义一致
        args += ["-no-reboot"]
        // 关人类 monitor (仅 QMP 控制, 防 stdio 干扰)
        args += ["-monitor", "none"]

        // ---- UEFI firmware ----
        // Linux: 单 -bios; Windows: 双 pflash (RW NVRAM 才能保 SecureBoot 状态)
        let edk2Code = inputs.qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-code.fd").path
        switch cfg.guestOS {
        case .linux:
            args += ["-bios", edk2Code]
        case .windows:
            // RO code + RW vars (vars 文件由 BundleLayout.nvramURL 持久化)
            let nvramPath = inputs.bundleURL.appendingPathComponent("nvram/efi-vars.fd").path
            args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(edk2Code)"]
            args += ["-drive", "if=pflash,format=raw,file=\(nvramPath)"]
        case .macOS:
            // 上面已 throw, 此处仅穷尽 switch
            break
        }
        // -L: QEMU 找 keymap / firmware descriptor 等辅助资源
        args += ["-L", inputs.qemuRoot.appendingPathComponent("share/qemu").path]

        // ---- 磁盘 (virtio-blk + raw, 顺序与 cfg.disks 一致) ----
        for disk in cfg.disks {
            let path = inputs.bundleURL.appendingPathComponent(disk.path).path
            var spec = "file=\(path),if=virtio,format=raw,cache=none"
            if disk.readOnly {
                spec += ",readonly=on"
            }
            args += ["-drive", spec]
        }

        // ---- 安装 ISO (仅 bootFromDiskOnly=false 时挂) ----
        // virtio-blk media=cdrom: 性能比 IDE-cdrom 好, Linux/Windows installer 都认
        if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
            args += ["-drive", "file=\(iso),if=virtio,media=cdrom,readonly=on"]
        }

        // ---- virtio-win 驱动 ISO (仅 windows guest, 第二 cdrom) ----
        // Win11 装机看不到 virtio-blk 主盘, 必须从 virtio-win.iso 加载 viostor.sys
        // 非 windows guest 即便传了 path 也不挂 (省得 Linux 装机界面多个空 cdrom 干扰)
        if cfg.guestOS == .windows, let virtioWinPath = inputs.virtioWinISOPath {
            args += ["-drive", "file=\(virtioWinPath),if=virtio,media=cdrom,readonly=on"]
        }

        // ---- 网络 ----
        for (idx, net) in cfg.networks.enumerated() {
            let netId = "net\(idx)"
            switch net.mode {
            case .nat:
                // user-mode NAT: QEMU 自带 SLIRP, 与 VZ NAT 语义对齐
                args += ["-netdev", "user,id=\(netId)"]
                args += ["-device", "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)"]
            case .bridged:
                // vmnet-bridged 需要 entitlement + 接口检查, QEMU 后端一期不实现
                throw HVMError.backend(.configInvalid(
                    field: "networks[\(idx)].mode",
                    reason: "bridged 网络在 QEMU 后端尚未实现, 改用 nat 或等待后续版本"
                ))
            }
        }

        // ---- 显示 ----
        // cocoa: QEMU 自开 NSWindow. 与 HVMDisplay 嵌入主窗口的集成留给后续 commit
        args += ["-display", "cocoa"]

        // ---- QMP 控制 ----
        // server=on: QEMU 监听 socket; wait=off: 不阻塞 QEMU 启动等客户端
        args += ["-qmp", "unix:\(inputs.qmpSocketPath),server=on,wait=off"]

        // ---- Win11 TPM 2.0 (仅 windows + tpmEnabled 时) ----
        // swtpm daemon 需另进程启动 (ProcessRunner 之外的事), 这里只生成 QEMU 端 args
        if cfg.guestOS == .windows, cfg.windows?.tpmEnabled == true {
            let tpmSock = inputs.bundleURL.appendingPathComponent("run/swtpm.sock").path
            args += ["-chardev", "socket,id=chartpm,path=\(tpmSock)"]
            args += ["-tpmdev", "emulator,id=tpm0,chardev=chartpm"]
            args += ["-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        return args
    }
}
