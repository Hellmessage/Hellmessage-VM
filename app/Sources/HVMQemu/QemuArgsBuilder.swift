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
        /// swtpm 控制 socket 绝对路径 (仅 windows + tpmEnabled 时用).
        /// nil 时即便 windows.tpmEnabled=true 也不注入 TPM args (调用方负责事先启动 swtpm).
        public let swtpmSocketPath: String?
        /// guest serial console 的 unix socket 绝对路径 (QEMU 当 server, HVMHost 当 client).
        /// nil 时不挂 chardev/serial — 仅在 hvm-dbg console.* 不需要时跳过 (一期总是传).
        public let consoleSocketPath: String?

        public init(
            config: VMConfig,
            bundleURL: URL,
            qemuRoot: URL,
            qmpSocketPath: String,
            virtioWinISOPath: String? = nil,
            swtpmSocketPath: String? = nil,
            consoleSocketPath: String? = nil
        ) {
            self.config = config
            self.bundleURL = bundleURL
            self.qemuRoot = qemuRoot
            self.qmpSocketPath = qmpSocketPath
            self.virtioWinISOPath = virtioWinISOPath
            self.swtpmSocketPath = swtpmSocketPath
            self.consoleSocketPath = consoleSocketPath
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

        // ---- guest serial console (chardev unix socket, 给 QemuConsoleBridge 接) ----
        // QEMU 以 server 身份 listen, HVMHost 启动后立即 connect 当 client.
        // wait=off: QEMU 不等客户端连上才启动 (避免 boot 卡死).
        // 路径由调用方注入 (typical: HVMPaths.runDir/<vm-id>.console.sock); nil 跳过.
        if let consSock = inputs.consoleSocketPath {
            args += ["-chardev", "socket,id=cons0,path=\(consSock),server=on,wait=off"]
            args += ["-serial", "chardev:cons0"]
        }

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

        // ---- 磁盘 (virtio-blk, 顺序与 cfg.disks 一致). format 直接读 disk.format 字段, 不推断: ----
        //   DiskFormat.qcow2 → qcow2 (新建 QEMU VM 默认)
        //   DiskFormat.raw   → raw   (VZ 后端格式; 老 raw QEMU VM 仍可跑)
        for disk in cfg.disks {
            let pathStr = inputs.bundleURL.appendingPathComponent(disk.path).path
            var spec = "file=\(pathStr),if=virtio,format=\(disk.format.rawValue),cache=none"
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
        // bridged / shared 走系统级 socket_vmnet daemon (launchd 拉起, 见 scripts/install-vmnet-helper.sh).
        // QEMU 用 -netdev stream 连固定 socket 路径, 不再 per-VM spawn sidecar.
        for (idx, net) in cfg.networks.enumerated() {
            let netId = "net\(idx)"
            switch net.mode {
            case .nat:
                // user-mode NAT: QEMU 自带 SLIRP, 与 VZ NAT 语义对齐 (无需任何 daemon)
                args += ["-netdev", "user,id=\(netId)"]
                args += ["-device", "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)"]
            case .bridged(let iface):
                let sockPath = VmnetDaemonPaths.bridgedSocket(interface: iface)
                guard VmnetDaemonPaths.isReady(sockPath) else {
                    throw HVMError.backend(.configInvalid(
                        field: "networks[\(idx)].mode",
                        reason: "bridged(\(iface)) 需要 socket_vmnet daemon 在 \(sockPath); " +
                                "请跑: sudo scripts/install-vmnet-helper.sh \(iface)"
                    ))
                }
                args += ["-netdev", "stream,id=\(netId),addr.type=unix,addr.path=\(sockPath),server=off"]
                args += ["-device", "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)"]
            case .shared:
                let sockPath = VmnetDaemonPaths.sharedSocket
                guard VmnetDaemonPaths.isReady(sockPath) else {
                    throw HVMError.backend(.configInvalid(
                        field: "networks[\(idx)].mode",
                        reason: "shared 需要 socket_vmnet daemon 在 \(sockPath); " +
                                "请跑: sudo scripts/install-vmnet-helper.sh"
                    ))
                }
                args += ["-netdev", "stream,id=\(netId),addr.type=unix,addr.path=\(sockPath),server=off"]
                args += ["-device", "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)"]
            }
        }

        // ---- 显示 + 输入 ----
        // QEMU virt 机器默认无显卡, 只有 serial/parallel console; 必须显式加 GPU 才能出 graphical UEFI/OS UI.
        // virtio-gpu-pci: 现代 virtio GPU, Linux 内核自带 driver; Windows arm64 装机界面要从 ISO 加载
        // virtio GPU driver (virtio-win.iso 提供) 才能跳出 1080p, 装机阶段会先以 EDK2 GOP 出图.
        args += ["-device", "virtio-gpu-pci"]
        // USB xHCI 控制器 + USB 键盘 + USB tablet (绝对坐标鼠标; hvm-dbg mouse abs 注入也走它)
        args += ["-device", "qemu-xhci,id=xhci"]
        args += ["-device", "usb-kbd,bus=xhci.0"]
        args += ["-device", "usb-tablet,bus=xhci.0"]
        // cocoa: QEMU 自开 NSWindow. 与 HVMDisplay 嵌入主窗口的集成留给后续 commit
        args += ["-display", "cocoa"]

        // ---- QMP 控制 ----
        // server=on: QEMU 监听 socket; wait=off: 不阻塞 QEMU 启动等客户端
        args += ["-qmp", "unix:\(inputs.qmpSocketPath),server=on,wait=off"]

        // ---- Win11 TPM 2.0 (仅 windows + tpmEnabled + 调用方已启 swtpm) ----
        // swtpm daemon 由 SwtpmRunner 在外部先启起, socket 路径由调用方注入 (避免硬编码 bug).
        // 没传 swtpmSocketPath 即便 windows.tpmEnabled=true 也不挂 TPM device — Win11 装机会
        // 在 TPM 检查处失败, 调用方负责检测并报错.
        if cfg.guestOS == .windows,
           cfg.windows?.tpmEnabled == true,
           let tpmSock = inputs.swtpmSocketPath {
            args += ["-chardev", "socket,id=chartpm,path=\(tpmSock)"]
            args += ["-tpmdev", "emulator,id=tpm0,chardev=chartpm"]
            args += ["-device", "tpm-tis-device,tpmdev=tpm0"]
        }

        return args
    }
}
