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

    /// build() 输出.
    /// vmnetSocketPaths: 按 networks 顺序里 bridged/shared NIC 出现的顺序排列 daemon
    /// socket 路径. 调用方必须把这 N 个 socket 的连接 fd 在子进程里依次落到 fd 3, 4, ...,
    /// QEMU 命令行也按这个 fd 顺序写 -netdev socket,id=netN,fd=K (与 lima/colima 实现一致).
    /// 不再走 socket_vmnet_client wrapper (单 fd 限制, 不支持多 NIC).
    /// 空数组 = 全 NAT 或无 networks, 调用方直接 spawn qemu-system-aarch64.
    public struct BuildResult: Sendable {
        public let args: [String]
        public let vmnetSocketPaths: [String]
        public init(args: [String], vmnetSocketPaths: [String]) {
            self.args = args
            self.vmnetSocketPaths = vmnetSocketPaths
        }
    }

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
        /// AutoUnattend ISO 绝对路径 (仅 windows + bypassInstallChecks 时由调用方注入).
        /// 由 WindowsUnattend.ensureISO 启动前生成. nil 不挂第二 cdrom.
        public let unattendISOPath: String?
        /// HDP iosurface 显示后端的 host socket 路径 (BundleLayout.iosurfaceSocketURL).
        /// 非 nil 时 argv 用 `-display iosurface,socket=...` 替代 cocoa, host 端
        /// HVMDisplayQemu.DisplayChannel 连此 socket 拉 framebuffer.
        public let iosurfaceSocketPath: String?
        /// 输入专用 QMP socket. 非 nil 时额外加一个 `-qmp unix:...,server=on,wait=off`,
        /// 给 HVMDisplayQemu.InputForwarder 用 (跟 control QMP 分离, 避免 accept 争抢).
        public let qmpInputSocketPath: String?
        /// spice-vdagent virtio-serial chardev socket. 非 nil 时 argv 加
        /// virtio-serial-pci + chardev + virtserialport 三件套, guest 内安装
        /// spice-vdagent 后即可响应 host 的 RESIZE_REQUEST → EDID 变化做动态分辨率.
        public let vdagentSocketPath: String?

        public init(
            config: VMConfig,
            bundleURL: URL,
            qemuRoot: URL,
            qmpSocketPath: String,
            virtioWinISOPath: String? = nil,
            swtpmSocketPath: String? = nil,
            consoleSocketPath: String? = nil,
            unattendISOPath: String? = nil,
            iosurfaceSocketPath: String? = nil,
            qmpInputSocketPath: String? = nil,
            vdagentSocketPath: String? = nil
        ) {
            self.config = config
            self.bundleURL = bundleURL
            self.qemuRoot = qemuRoot
            self.qmpSocketPath = qmpSocketPath
            self.virtioWinISOPath = virtioWinISOPath
            self.swtpmSocketPath = swtpmSocketPath
            self.consoleSocketPath = consoleSocketPath
            self.unattendISOPath = unattendISOPath
            self.iosurfaceSocketPath = iosurfaceSocketPath
            self.qmpInputSocketPath = qmpInputSocketPath
            self.vdagentSocketPath = vdagentSocketPath
        }
    }

    /// 构造 argv + 网络元信息. 调用方按 BuildResult.vmnetSocketPath 决定是否套
    /// socket_vmnet_client wrapper.
    public static func build(_ inputs: Inputs) throws -> BuildResult {
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
        // hvm-win11-lowram=on (仅 windows guest, 且 env HVM_QEMU_WIN11_LOWRAM=1 时):
        //   我们 patch 过的 QEMU 自带选项, 在 0x10000000 挂 16MB RAM 孔, 让
        //   Win11 ARM64 bootmgfw 能成功 ConvertPages. **要求配套 patch 过的 EDK2 firmware**;
        //   stock kraxel firmware 看到 0x10000000 /memory 节点会 ASSERT 挂死, 所以默认关.
        //   开启路径: 跑 scripts/edk2-build.sh build 出 patched firmware 拷进 stage, 再 export
        //   HVM_QEMU_WIN11_LOWRAM=1 启动 Win11 VM. 详见 docs/QEMU_INTEGRATION.md.
        var machineOpts = "virt,gic-version=3"
        if cfg.guestOS == .windows,
           ProcessInfo.processInfo.environment["HVM_QEMU_WIN11_LOWRAM"] == "1" {
            machineOpts += ",hvm-win11-lowram=on"
        }
        args += ["-machine", machineOpts]
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
        // Linux: 用 stock kraxel firmware (QEMU 自带, 跟 Ubuntu/Linux ISO 兼容良好), 单 -bios.
        // Windows: 必须用 patched EDK2 firmware (含 ArmVirtPkg extra-RAM-region patch, Win11
        //          ARM64 bootmgfw 在 0x10000000 的 ConvertPages 才能成功). 走双 pflash:
        //          RO code (firmware) + RW vars (nvram, SecureBoot 状态持久).
        //          Win11 firmware 文件名 edk2-aarch64-code-win11.fd, 由 scripts/edk2-build.sh
        //          自家 build (可能), 暂时 vendor hell-vm 项目同源 binary (GPL 兼容, 出处声明).
        let stockEdk2 = inputs.qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-code.fd").path
        let win11Edk2 = inputs.qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-code-win11.fd").path
        switch cfg.guestOS {
        case .linux:
            args += ["-bios", stockEdk2]
        case .windows:
            // RW vars (vars 文件由 BundleLayout.nvramURL 持久化)
            let nvramPath = inputs.bundleURL.appendingPathComponent("nvram/efi-vars.fd").path
            args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(win11Edk2)"]
            args += ["-drive", "if=pflash,format=raw,file=\(nvramPath)"]
        case .macOS:
            // 上面已 throw, 此处仅穷尽 switch
            break
        }
        // -L: QEMU 找 keymap / firmware descriptor 等辅助资源
        args += ["-L", inputs.qemuRoot.appendingPathComponent("share/qemu").path]

        // ---- USB 控制器 (xhci) ----
        // 必须在所有 usb-* 设备之前定义, 否则 -device usb-storage,bus=xhci.0 找不到 bus.
        // Windows ISO 走 usb-storage cdrom (Win11 EFI bootloader 必需), Linux 也保留 (键鼠 USB).
        args += ["-device", "qemu-xhci,id=xhci"]

        // ---- 磁盘 (按 guestOS 分总线类型, 顺序与 cfg.disks 一致). format 直接读 disk.format, 不推断: ----
        //   DiskFormat.qcow2 → qcow2 (新建 QEMU VM 默认)
        //   DiskFormat.raw   → raw   (VZ 后端格式; 老 raw QEMU VM 仍可跑)
        // 总线分流:
        //   Windows: -drive if=none + -device nvme (Win11 ARM PE 内置 NVMe 驱动, 装机器直接看见盘.
        //            virtio-blk 在 PE 阶段需要手动加载 viostor.inf, 体验差; hell-vm 已验证 NVMe 路线.)
        //   Linux:   -drive if=virtio (内核 virtio-blk 驱动稳, 不切换避免回归)
        for (idx, disk) in cfg.disks.enumerated() {
            let pathStr = inputs.bundleURL.appendingPathComponent(disk.path).path
            let driveId = "disk\(idx)"
            var spec = "file=\(pathStr),id=\(driveId),format=\(disk.format.rawValue),cache=none"
            if disk.readOnly {
                spec += ",readonly=on"
            }
            switch cfg.guestOS {
            case .windows:
                spec += ",if=none"
                args += ["-drive", spec]
                args += ["-device", "nvme,drive=\(driveId),serial=hvm-\(driveId)"]
            case .linux:
                spec += ",if=virtio"
                args += ["-drive", spec]
            case .macOS:
                // 上面已 throw, 此处仅穷尽 switch
                break
            }
        }

        // ---- 安装 ISO + 周边 cdrom ----
        // Linux: virtio-cdrom (Ubuntu installer 已验证能 boot)
        // Windows: usb-storage cdrom + bootindex=0 (Win11 EFI bootloader 实测要 USB 路径,
        //          virtio-cdrom 在 BdsDxe loading Boot0002 后 hang 不进 wpe.wim).
        //          挂法跟 hell-vm graphical 模式一致.
        if cfg.guestOS == .windows {
            // Windows 装机 ISO: usb-storage cdrom (bootindex=0)
            if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
                args += ["-drive", "if=none,id=cdrom_inst,media=cdrom,file=\(iso),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_inst,id=cdrom_inst_dev,removable=true,bootindex=0,bus=xhci.0"]
            }
            // unattend ISO: usb-storage 第二 cdrom (Win Setup 自动扫所有移动介质找 Autounattend.xml)
            if let unattendPath = inputs.unattendISOPath {
                args += ["-drive", "if=none,id=cdrom_unat,media=cdrom,file=\(unattendPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_unat,id=cdrom_unat_dev,removable=true,bus=xhci.0"]
            }
            // virtio-win 驱动 ISO: usb-storage 第三 cdrom (装机看不到 virtio-blk 主盘必经)
            if let virtioWinPath = inputs.virtioWinISOPath {
                args += ["-drive", "if=none,id=cdrom_vio,media=cdrom,file=\(virtioWinPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_vio,id=cdrom_vio_dev,removable=true,bus=xhci.0"]
            }
        } else {
            // Linux/macOS: virtio-cdrom 维持原状 (Ubuntu 24.04 已验证)
            if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
                args += ["-drive", "file=\(iso),if=virtio,media=cdrom,readonly=on"]
            }
        }

        // ---- 网络 ----
        // bridged / shared 走系统级 socket_vmnet daemon (launchd 拉起, 见 scripts/install-vmnet-helper.sh).
        // socket_vmnet daemon 协议: 4-byte length prefix per packet, 与 QEMU 的
        // -netdev stream (裸字节流) 不匹配. 也不能走 socket_vmnet_client wrapper,
        // 因为 wrapper 只透传单一 fd, 不支持多 NIC.
        // 实现: 父进程 (HVMHost / hvm-dbg) 自己 connect 每个 daemon, 用 posix_spawn 把
        // N 个 fd 落到子进程的 fd 3, 4, 5...; QEMU argv 写 -netdev socket,id=netN,fd=K.
        // 这是 lima / colima 真实做法, 见 lima pkg/driver/qemu/qemu_driver.go fd_connect.
        // BuildResult.vmnetSocketPaths 给调用方 daemon socket 列表, 顺序 = fd 3..3+N-1.
        let vmnetFdBase: Int32 = 3
        var vmnetSocketPaths: [String] = []
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
                let fd = vmnetFdBase + Int32(vmnetSocketPaths.count)
                vmnetSocketPaths.append(sockPath)
                args += ["-netdev", "socket,id=\(netId),fd=\(fd)"]
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
                let fd = vmnetFdBase + Int32(vmnetSocketPaths.count)
                vmnetSocketPaths.append(sockPath)
                args += ["-netdev", "socket,id=\(netId),fd=\(fd)"]
                args += ["-device", "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)"]
            }
        }

        // ---- 显示 + 输入 ----
        // QEMU virt 机器默认无显卡, 只有 serial/parallel console; 必须显式加 GPU 才能出 graphical UEFI/OS UI.
        // Linux: virtio-gpu-pci (内核自带 driver, 加速); Windows ARM64: 必须只挂 ramfb,
        // 因为 bootmgfw.efi 跟 virtio-gpu-pci GOP 实测有冲突会 hang (hell-vm 同款约束).
        // ramfb 是 sysbus framebuffer, EDK2 通过 fw_cfg 暴露给 GOP, Win bootmgr 兼容.
        if cfg.guestOS == .windows {
            args += ["-device", "ramfb"]
        } else {
            args += ["-device", "virtio-gpu-pci"]
        }
        // USB 键盘 + USB tablet (xhci controller 已在 ISO 之前定义, 避免 bus=xhci.0 forward ref).
        // tablet 给绝对坐标鼠标 (hvm-dbg mouse abs 注入也走它).
        args += ["-device", "usb-kbd,bus=xhci.0"]
        args += ["-device", "usb-tablet,bus=xhci.0"]
        // -display 后端: 优先 iosurface (HDP, 嵌入主窗口零拷贝), 否则回退 cocoa
        // (调试用, 自开独立 NSWindow). 由 inputs.iosurfaceSocketPath 是否注入决定.
        if let iosurfaceSocket = inputs.iosurfaceSocketPath {
            args += ["-display", "iosurface,socket=\(iosurfaceSocket)"]
        } else {
            args += ["-display", "cocoa"]
        }

        // spice-vdagent virtio-serial 通道: 给 guest 内 spice-vdagent agent 用,
        // host 端不连接此 socket. 装了 vdagent 的 guest 收到 EDID 变化会自动改
        // 分辨率, 配合 HDP RESIZE_REQUEST 实现动态分辨率.
        if let vdagentSocket = inputs.vdagentSocketPath {
            args += ["-device", "virtio-serial-pci,id=vsp0"]
            args += ["-chardev", "socket,id=vdagent,path=\(vdagentSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=vdagent,name=com.redhat.spice.0"]
        }

        // ---- QMP 控制 ----
        // server=on: QEMU 监听 socket; wait=off: 不阻塞 QEMU 启动等客户端
        args += ["-qmp", "unix:\(inputs.qmpSocketPath),server=on,wait=off"]
        // 输入专用 QMP (HVMDisplayQemu.InputForwarder 用, 走 input-send-event)
        if let qmpInputSocket = inputs.qmpInputSocketPath {
            args += ["-qmp", "unix:\(qmpInputSocket),server=on,wait=off"]
        }

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

        return BuildResult(args: args, vmnetSocketPaths: vmnetSocketPaths)
    }
}
