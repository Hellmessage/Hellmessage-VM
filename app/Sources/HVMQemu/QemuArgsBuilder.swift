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

    /// build() 输出. 现仅含 argv: 桥接 (vmnet bridged/shared) 功能已临时禁用,
    /// 父进程不再 fd 透传到 QEMU; .bridged/.shared 启动会抛 configInvalid.
    /// 后续接 hell-vm 风格新方案时再恢复 — 那时 argv 直接走
    /// `-netdev stream,addr.type=unix,addr.path=...` 不需要 fd 透传, 此 struct 不必扩.
    public struct BuildResult: Sendable {
        public let args: [String]
        public init(args: [String]) {
            self.args = args
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
        /// UTM Guest Tools ISO 绝对路径 (仅 windows + 由 UtmGuestToolsCache 提供). 非 nil 时
        /// 挂第四 cdrom (usb-storage), guest 内 OOBE FirstLogonCommands 扫所有盘符跑
        /// utm-guest-tools-*.exe /S 静默装 ARM64 native vdagent + utmapp 自家 viogpudo
        /// + qemu-ga.exe 服务. 缺时 OOBE 那条 cmd noop, 不阻塞流程.
        public let utmGuestToolsISOPath: String?
        /// qemu-guest-agent virtio-serial chardev socket. 非 nil 时 argv 加 chardev qga +
        /// virtserialport name=org.qemu.guest_agent.0, guest 内 qemu-ga.exe 服务 (UTM
        /// Guest Tools 装包含 qemu-ga-x86_64.msi) 自动 attach. host 通过本 socket 发
        /// guest-exec JSON 跑 PowerShell / cmd, 是 hvm-dbg exec-guest 的底层通路.
        public let qgaSocketPath: String?

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
            vdagentSocketPath: String? = nil,
            utmGuestToolsISOPath: String? = nil,
            qgaSocketPath: String? = nil
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
            self.utmGuestToolsISOPath = utmGuestToolsISOPath
            self.qgaSocketPath = qgaSocketPath
        }
    }

    /// 构造 argv. 当前仅支持 .nat NIC; .bridged/.shared 抛 configInvalid (桥接路径
    /// 临时禁用, 等待 hell-vm 风格新方案接上).
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

        // -no-reboot 仅装机阶段加 (cfg.bootFromDiskOnly=false): installer 拷完文件触发
        // reboot 时让 QEMU 直接退出, 给用户决策点 — 在 GUI 点"安装完成"切到
        // bootFromDiskOnly=true 后再 cold start, 不再挂 ISO 直接 boot 主硬盘.
        //   Windows: 阶段 1 (装机) 加, 阶段 2 (安装完成) / 阶段 3 (驱动完成) 都不加,
        //            guest reboot 走 system_reset host 子进程不退 — OOBE / 装驱动重启走这条.
        //   Linux:   装机阶段加, bootFromDiskOnly=true 之后不加 — 跟 Win 阶段 1→2 同语义.
        // 设备分流见下方 -device 段三态注释 (仅 Windows 三态).
        if (cfg.guestOS == .windows || cfg.guestOS == .linux) && !cfg.bootFromDiskOnly {
            args += ["-no-reboot"]
        }
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
            // 阶段 3 (驱动已装完, hvm-gpu-ramfb-pci 接管): 把 unattend / UTM Guest Tools cdrom 卸掉,
            // OS 已自给, 不需要再挂安装期辅助介质. installerISO 也由 !bootFromDiskOnly 自然不挂.
            let windowsFullyInstalled = cfg.bootFromDiskOnly && cfg.windowsDriversInstalled
            // Windows 装机 ISO: usb-storage cdrom (bootindex=0)
            if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
                args += ["-drive", "if=none,id=cdrom_inst,media=cdrom,file=\(iso),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_inst,id=cdrom_inst_dev,removable=true,bootindex=0,bus=xhci.0"]
            }
            // unattend ISO: usb-storage 第二 cdrom (Win Setup 自动扫所有移动介质找 Autounattend.xml)
            if !windowsFullyInstalled, let unattendPath = inputs.unattendISOPath {
                args += ["-drive", "if=none,id=cdrom_unat,media=cdrom,file=\(unattendPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_unat,id=cdrom_unat_dev,removable=true,bus=xhci.0"]
            }
            // virtio-win 驱动 ISO: **当前默认禁用** — UTM Guest Tools ISO 内含 ARM64
            // native NetKVM/viostor/viogpudo + qemu-ga, 已覆盖 virtio-win.iso 该负责的
            // 驱动事项. 主硬盘走 nvme (Win 自带 inbox driver) 装机阶段也不依赖 virtio-blk.
            // virtioWinISOPath 字段保留为 fallback 入口, 后续若需要老 virtio-win.iso 通路
            // 把下面 `false &&` 去掉即恢复挂 cdrom_vio. (相应 unattend pnputil 段由
            // VMConfig.windows.autoInstallVirtioWin 控制, 同样默认关闭.)
            if false, let virtioWinPath = inputs.virtioWinISOPath {
                args += ["-drive", "if=none,id=cdrom_vio,media=cdrom,file=\(virtioWinPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_vio,id=cdrom_vio_dev,removable=true,bus=xhci.0"]
            }
            // UTM Guest Tools ISO: usb-storage 第四 cdrom (含 ARM64 native vdagent + utmapp
            // 自家 viogpudo + qemu-ga). OOBE FirstLogonCommands 扫所有盘符跑里面的
            // utm-guest-tools-*.exe NSIS installer /S 静默装. ~120MB 不打进 unattend ISO.
            if !windowsFullyInstalled, let utmToolsPath = inputs.utmGuestToolsISOPath {
                args += ["-drive", "if=none,id=cdrom_utm,media=cdrom,file=\(utmToolsPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_utm,id=cdrom_utm_dev,removable=true,bus=xhci.0"]
            }
        } else {
            // Linux/macOS: virtio-cdrom 维持原状 (Ubuntu 24.04 已验证)
            if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
                args += ["-drive", "file=\(iso),if=virtio,media=cdrom,readonly=on"]
            }
        }

        // ---- PCIe root ports ----
        // ARM virt 机器的默认 root bus `pcie.0` 是 PCIe-to-PCI legacy bridge — 设备挂上去
        // 走 transitional / PCI 模式, 用 legacy MSI 而不是 MSI-X 中断. virtio-net-pci 在
        // legacy bus 上**高 frame rate 时丢中断** (实测 vmnet bridged DHCP / broadcast 频次
        // 下 guest 收不到 frame, NAT 低 traffic 没问题). hell-vm 同款做法: 启动时预定义 4 个
        // pcie-root-port, NIC 挂上去走 PCIe native MSI-X, 中断可靠.
        //   chassis 必须 >=1 (chassis 0 保留); 每 root port 独占一个 chassis.
        //   4 个槽位日常够用, 多 NIC 超出会落回 pcie.0 (legacy fallback, 跟之前行为一致).
        for i in 0..<4 {
            args += ["-device", "pcie-root-port,id=rp\(i),chassis=\(i + 1)"]
        }

        // ---- 网络 ----
        // .nat: QEMU user-mode SLIRP (与 VZ NAT 语义对齐, 无 daemon 依赖).
        // .bridged/.shared: 桥接路径临时禁用 — 老的 socket_vmnet 自家方案已下线,
        //   hell-vm 风格新方案 (osascript admin privileges 一次装 launchd daemon +
        //   `-netdev stream,addr.type=unix,addr.path=<sock>` 直连 daemon) 后续接上.
        //   此时直接抛 configInvalid 让用户切回 NAT 或等新方案.
        // bus= 关键: NIC 必须挂到 pcie-root-port (rp_N) 走 PCIe native, 不能落 pcie.0
        //   legacy bridge — 见上节 "PCIe root ports" 注释.
        for (idx, net) in cfg.networks.enumerated() {
            let netId = "net\(idx)"
            let busOpt = idx < 4 ? ",bus=rp\(idx)" : ""
            let deviceOpts = "virtio-net-pci,netdev=\(netId),mac=\(net.macAddress)\(busOpt)"
            switch net.mode {
            case .nat:
                args += ["-netdev", "user,id=\(netId)"]
                args += ["-device", deviceOpts]
            case .bridged, .shared:
                throw HVMError.backend(.configInvalid(
                    field: "networks[\(idx)].mode",
                    reason: "vmnet 桥接 / shared 网络当前临时禁用 (重写中, 切换 hell-vm 风格新方案); 请改用 NAT"
                ))
            }
        }
        // ---- 显示 + 输入 ----
        // QEMU virt 机器默认无显卡, 只有 serial/parallel console; 必须显式加 GPU 才能出 graphical UEFI/OS UI.
        //
        // Linux: virtio-gpu-pci (内核自带 driver, 加速; OS 期 set_scanout 即可 dynamic resize)
        //
        // Windows ARM64: 三态切换, 由 (bootFromDiskOnly, windowsDriversInstalled) 决定:
        //  - 阶段 1 (bootFromDiskOnly=false, 装机): -device ramfb 单挂. Win Setup / WinPE
        //    走 BDD 软件画法 (cursor + 像素都直接画进 ramfb cpu_physical_memory_map 出来的
        //    buffer), 跟单设备路径完全兼容, 不会有 virtio-gpu reset_bh 清 console surface
        //    的 placeholder 问题. -no-reboot 在上面那条已加, Setup 第一次 reboot 时 QEMU
        //    退出, 给用户切阶段 2 的决策点.
        //  - 阶段 2 (bootFromDiskOnly=true, windowsDriversInstalled=false, 装驱动): 仍 ramfb
        //    单挂. OS 已起来但 viogpudo 没装, 这阶段用户跑 UTM Guest Tools 装 viogpudo /
        //    qemu-guest-agent. 跟阶段 1 同样走 ramfb 是因为 hvm-gpu-ramfb-pci 在没驱动时
        //    OS 端只 enumerate 出 "Microsoft Basic Display" → BDD 路径必须 ramfb 兜.
        //  - 阶段 3 (bootFromDiskOnly=true, windowsDriversInstalled=true, 运行): hvm-gpu-ramfb-pci
        //    (patches/qemu/0003 自家融合设备), boot 期走 ramfb 兼容 EDK2/bootmgfw, OS 期
        //    viogpudo.sys 绑 PCI 1AF4:1050 切到 virtio-gpu 路径做 dynamic resize. vendor/
        //    device id 复用 0x1AF4/0x1050, viogpudo.inf 自动 match.
        // 详见 patches/qemu/0003 注释.
        if cfg.guestOS == .windows {
            if cfg.bootFromDiskOnly && cfg.windowsDriversInstalled {
                args += ["-device", "hvm-gpu-ramfb-pci"]
            } else {
                args += ["-device", "ramfb"]
            }
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

        // virtio-serial bus (vsp0): vdagent / qga 任一启用就加, 共用同一条 bus 防重复.
        // (QEMU 不允许 -device virtio-serial-pci 加两次同 id; 也不能两个 id 各占总线
        //  浪费 PCI slot — 一条 vsp0 挂多 port 是 spice/qga 共用模式)
        let needsVirtioSerial = inputs.vdagentSocketPath != nil || inputs.qgaSocketPath != nil
        if needsVirtioSerial {
            args += ["-device", "virtio-serial-pci,id=vsp0"]
        }
        // spice-vdagent virtio-serial 通道: 给 guest 内 spice-vdagent agent 用,
        // host 端不连接此 socket. 装了 vdagent 的 guest 收到 EDID 变化会自动改
        // 分辨率, 配合 HDP RESIZE_REQUEST 实现动态分辨率.
        if let vdagentSocket = inputs.vdagentSocketPath {
            args += ["-chardev", "socket,id=vdagent,path=\(vdagentSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=vdagent,name=com.redhat.spice.0"]
        }
        // qemu-guest-agent (qemu-ga) 通路 — 给 hvm-dbg exec-guest 用, 走 virtio-serial
        // port org.qemu.guest_agent.0 跑 guest 内 PowerShell / cmd 命令拿 stdout/exit_code.
        // 配套 guest 内 qemu-ga.exe 服务 (UTM Guest Tools 装包含 qemu-ga-x86_64.msi).
        if let qgaSocket = inputs.qgaSocketPath {
            args += ["-chardev", "socket,id=qga,path=\(qgaSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=qga,name=org.qemu.guest_agent.0"]
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

        return BuildResult(args: args)
    }
}
