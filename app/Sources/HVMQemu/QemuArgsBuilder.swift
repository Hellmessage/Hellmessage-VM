// HVMQemu/QemuArgsBuilder.swift
// 纯函数: VMConfig + bundleURL + 路径 → qemu-system-aarch64 的 argv.
//
// 关键约束:
//   - 不做 IO (磁盘/ISO 存在性是 BundleIO/StorageValidator 的责任)
//   - HVF 加速 + cpu host 标配, 不允许 fallback 到 TCG
//   - QMP socket 走 unix domain, 严禁 TCP (CLAUDE.md QEMU 后端约束)
//   - 输出顺序固定 (便于测试 + 排错)

import Foundation
import HVMBundle
import HVMCore

public enum QemuArgsBuilder {

    /// build() 输出 (仅 argv).
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
        /// virtio-win.iso 全局缓存路径 (仅 windows; nil 不挂 cdrom)
        public let virtioWinISOPath: String?
        /// swtpm 控制 socket (仅 windows + tpmEnabled; nil 不注入 TPM args, 调用方负责先启 swtpm)
        public let swtpmSocketPath: String?
        /// guest serial console unix socket (QEMU server, HVMHost client; nil 不挂 chardev/serial)
        public let consoleSocketPath: String?
        /// AutoUnattend ISO (仅 windows + bypassInstallChecks; nil 不挂 cdrom)
        public let unattendISOPath: String?
        /// HDP iosurface 显示后端 host socket. 非 nil 走 `-display iosurface`, host 端连此拉 framebuffer
        public let iosurfaceSocketPath: String?
        /// 输入专用 QMP socket (HVMDisplayQemu.InputForwarder 用, 跟 control QMP 分离避免 accept 争抢)
        public let qmpInputSocketPath: String?
        /// spice-vdagent virtio-serial chardev socket. guest 装 vdagent 后响应 RESIZE_REQUEST 做动态分辨率
        public let vdagentSocketPath: String?
        /// UTM Guest Tools ISO (仅 windows). 非 nil 挂 cdrom, OOBE 扫盘符跑 /S 静默装 vdagent + viogpudo + qemu-ga
        public let utmGuestToolsISOPath: String?
        /// qemu-guest-agent virtio-serial chardev socket. host 发 guest-exec 跑命令, 是 hvm-dbg exec-guest 底层通路
        public let qgaSocketPath: String?
        /// SPICE WebDAV virtio-serial chardev socket (host ↔ guest 共享目录).
        /// host 端 SpiceWebdavServer 在此跑 WebDAV server; 仅 sharedFolders 非空时设
        public let webdavSocketPath: String?

        /// HVM 自家 guest helper chardev socket. guest helper 收指令调 OleSetClipboard 设 Win 剪贴板;
        /// 仅 QEMU + Windows guest 时设, host 端 HVMFileClipboardBridge 作 client 连入
        public let hvmClipboardSocketPath: String?

        // ---- 加密 (qemu-perfile) ----
        /// 加密 LUKS qcow2 盘的 secret 文件路径 (LuksSecretFile 创建, 启动后立即 unlink). nil → 明文 disks
        public let qemuDiskSecretPath: String?
        /// 加密 OVMF VARS 的 secret 文件路径 (仅 windows + qemuPerfile). nil → 明文 efi-vars.fd raw
        public let qemuNvramSecretPath: String?

        /// QEMU `-pidfile <path>`: orphan 检测锚点, 下次启动 SidecarOrphanReaper 读此 pid kill 老 orphan
        public let qemuPidPath: String?

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
            qgaSocketPath: String? = nil,
            webdavSocketPath: String? = nil,
            hvmClipboardSocketPath: String? = nil,
            qemuDiskSecretPath: String? = nil,
            qemuNvramSecretPath: String? = nil,
            qemuPidPath: String? = nil
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
            self.webdavSocketPath = webdavSocketPath
            self.hvmClipboardSocketPath = hvmClipboardSocketPath
            self.qemuDiskSecretPath = qemuDiskSecretPath
            self.qemuNvramSecretPath = qemuNvramSecretPath
            self.qemuPidPath = qemuPidPath
        }
    }

    /// 构造 argv.
    public static func build(_ inputs: Inputs) throws -> BuildResult {
        let cfg = inputs.config

        var args: [String] = []

        // ---- 机器 + CPU + 加速器 ----
        // virt: aarch64 标准虚拟机型; gic-version=3 给现代 ARM Linux/Win 用
        // hvm-win11-lowram=on (仅 windows + env HVM_QEMU_WIN11_LOWRAM=1): patched QEMU 自带选项,
        //   在 0x10000000 挂 16MB RAM 孔让 Win11 ARM64 bootmgfw ConvertPages 成功.
        //   **要求配套 patched EDK2 firmware**; stock kraxel firmware 看到该 /memory 节点会 ASSERT, 故默认关.
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

        // -pidfile: orphan reaper 抓 orphan 的锚点. 调用方负责启动前 reap 老 pid + 清旧文件.
        if let pidPath = inputs.qemuPidPath {
            args += ["-pidfile", pidPath]
        }

        // -no-reboot 仅装机阶段加 (bootFromDiskOnly=false): installer 触发 reboot 时让 QEMU 退出,
        // 给用户在 GUI 点"安装完成"切 bootFromDiskOnly=true 再 cold start 的决策点.
        // bootFromDiskOnly=true 后不加 — guest reboot 走 system_reset 子进程不退 (OOBE / 装驱动重启).
        if (cfg.guestOS == .windows || cfg.guestOS == .linux) && !cfg.bootFromDiskOnly {
            args += ["-no-reboot"]
        }
        // 关人类 monitor (仅 QMP 控制, 防 stdio 干扰)
        args += ["-monitor", "none"]

        // ---- guest serial console (chardev unix socket, 给 QemuConsoleBridge 接) ----
        // QEMU 当 server listen, HVMHost connect 当 client. wait=off 不等客户端连上避免 boot 卡死.
        if let consSock = inputs.consoleSocketPath {
            args += ["-chardev", "socket,id=cons0,path=\(consSock),server=on,wait=off"]
            args += ["-serial", "chardev:cons0"]
        }

        // ---- UEFI firmware ----
        // Linux: stock kraxel firmware (QEMU 自带), 单 -bios.
        // Windows: 必须用 patched EDK2 firmware (含 extra-RAM-region patch, Win11 bootmgfw ConvertPages 才成功).
        //          走双 pflash: RO code + RW vars (nvram, SecureBoot 状态持久).
        let stockEdk2 = inputs.qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-code.fd").path
        let win11Edk2 = inputs.qemuRoot.appendingPathComponent("share/qemu/edk2-aarch64-code-win11.fd").path
        switch cfg.guestOS {
        case .linux:
            args += ["-bios", stockEdk2]
        case .windows:
            args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(win11Edk2)"]
            // RW vars: 加密 (qemu-perfile) 走 LUKS qcow2; 明文走 raw efi-vars.fd
            if let nvramSecret = inputs.qemuNvramSecretPath {
                let nvramPath = inputs.bundleURL
                    .appendingPathComponent("\(BundleLayout.nvramDirName)/\(BundleLayout.nvramLuksFileName)").path
                args += ["-object",
                         "secret,id=sec_nvram,file=\(nvramSecret),format=raw"]
                args += ["-drive",
                         "if=pflash,format=qcow2,file=\(nvramPath),encrypt.format=luks,encrypt.key-secret=sec_nvram"]
            } else {
                let nvramPath = inputs.bundleURL
                    .appendingPathComponent("\(BundleLayout.nvramDirName)/\(BundleLayout.nvramFileName)").path
                args += ["-drive", "if=pflash,format=raw,file=\(nvramPath)"]
            }
        }
        // -L: QEMU 找 keymap / firmware descriptor 等辅助资源
        args += ["-L", inputs.qemuRoot.appendingPathComponent("share/qemu").path]

        // ---- USB 控制器 (xhci) ----
        // 必须在所有 usb-* 设备之前定义, 否则 -device usb-storage,bus=xhci.0 找不到 bus.
        args += ["-device", "qemu-xhci,id=xhci"]

        // ---- 磁盘 (顺序与 cfg.disks 一致; format 直接读 disk.format 不推断) ----
        // 总线分流:
        //   Windows: -drive if=none + -device nvme (Win11 ARM PE 内置 NVMe 驱动, 装机直接见盘;
        //            virtio-blk 在 PE 阶段要手动加载 viostor.inf 体验差)
        //   Linux:   -drive if=virtio (内核 virtio-blk 驱动稳)
        // 加密 disks 时一次性注入 sec_disk secret object (所有 disks 共用同一 sub key);
        // 仅当至少有一块 qcow2 disk 时才 emit (raw disk 不走 LUKS).
        if let diskSecret = inputs.qemuDiskSecretPath,
           cfg.disks.contains(where: { $0.format == .qcow2 }) {
            args += ["-object", "secret,id=sec_disk,file=\(diskSecret),format=raw"]
        }
        for (idx, disk) in cfg.disks.enumerated() {
            let pathStr = inputs.bundleURL.appendingPathComponent(disk.path).path
            let driveId = "disk\(idx)"
            // 基础 spec: 加密 qcow2 加 encrypt.format=luks,encrypt.key-secret=sec_disk
            var spec = "file=\(pathStr),id=\(driveId),format=\(disk.format.rawValue),cache=none"
            if let _ = inputs.qemuDiskSecretPath, disk.format == .qcow2 {
                spec += ",encrypt.format=luks,encrypt.key-secret=sec_disk"
            }
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
            }
        }

        // ---- 安装 ISO + 周边 cdrom ----
        // Linux: virtio-cdrom; Windows: usb-storage cdrom + bootindex=0 (Win11 EFI bootloader 要 USB 路径,
        //        virtio-cdrom 在 BdsDxe loading Boot0002 后 hang 不进 wpe.wim).
        if cfg.guestOS == .windows {
            // 阶段 3 (驱动装完): OS 已自给, 卸掉 unattend / UTM Guest Tools cdrom.
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
            // virtio-win 驱动 ISO: **当前默认禁用** — UTM Guest Tools ISO 已含 ARM64 native
            // NetKVM/viostor/viogpudo + qemu-ga, 主硬盘走 nvme 不依赖 virtio-blk.
            // 字段保留为 fallback 入口: 去掉 `false &&` 即恢复挂 cdrom_vio.
            if false, let virtioWinPath = inputs.virtioWinISOPath {
                args += ["-drive", "if=none,id=cdrom_vio,media=cdrom,file=\(virtioWinPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_vio,id=cdrom_vio_dev,removable=true,bus=xhci.0"]
            }
            // UTM Guest Tools ISO: usb-storage cdrom (含 ARM64 native vdagent + viogpudo + qemu-ga).
            // OOBE 扫盘符跑 utm-guest-tools-*.exe /S 静默装. ~120MB 不打进 unattend ISO.
            if !windowsFullyInstalled, let utmToolsPath = inputs.utmGuestToolsISOPath {
                args += ["-drive", "if=none,id=cdrom_utm,media=cdrom,file=\(utmToolsPath),readonly=on"]
                args += ["-device", "usb-storage,drive=cdrom_utm,id=cdrom_utm_dev,removable=true,bus=xhci.0"]
            }
        } else {
            // Linux: virtio-cdrom
            if !cfg.bootFromDiskOnly, let iso = cfg.installerISO {
                args += ["-drive", "file=\(iso),if=virtio,media=cdrom,readonly=on"]
            }
        }

        // ---- PCIe root ports ----
        // ARM virt 默认 root bus `pcie.0` 是 PCIe-to-PCI legacy bridge, 走 legacy MSI 中断;
        // virtio-net-pci 挂上去在高 frame rate 时丢中断 (vmnet bridged DHCP/broadcast 下 guest 收不到帧).
        // 预定义 4 个 pcie-root-port 让 NIC 走 PCIe native MSI-X, 中断可靠.
        //   chassis 必须 >=1 (0 保留); 每 root port 独占一个 chassis. 超 4 NIC 落回 pcie.0 legacy fallback.
        for i in 0..<4 {
            args += ["-device", "pcie-root-port,id=rp\(i),chassis=\(i + 1)"]
        }

        // ---- 网络 ----
        // - .user: QEMU 内置 user-mode (SLIRP) NAT, 零依赖
        // - .vmnetShared/.vmnetHost/.vmnetBridged: 走系统级 socket_vmnet daemon, QEMU 直连
        //     `-netdev stream,addr.type=unix,addr.path=<sock>` (daemon 的 4-byte length-prefix
        //     framing 跟 QEMU stream 协议一致, 不需 wrapper / fd 透传). 缺 daemon 抛 configInvalid.
        // - .none / enabled=false: 跳过
        // bus= 关键: NIC 必须挂 pcie-root-port (rp_N), 不能落 pcie.0 legacy bridge (见上节).
        for (idx, net) in cfg.networks.enumerated() {
            guard net.enabled, net.mode != .none else { continue }
            let netId = "net\(idx)"
            let busOpt = idx < 4 ? ",bus=rp\(idx)" : ""
            let deviceOpts = "\(net.deviceModel.qemuDeviceName),netdev=\(netId),mac=\(net.macAddress)\(busOpt)"
            switch net.mode {
            case .user:
                args += ["-netdev", "user,id=\(netId)"]
            case .vmnetShared, .vmnetHost, .vmnetBridged:
                guard let sock = net.effectiveSocketPath else {
                    throw HVMError.backend(.configInvalid(
                        field: "networks[\(idx)].mode",
                        reason: "无法推导 vmnet socket 路径 (mode=\(net.mode.rawValue))"
                    ))
                }
                guard SocketPaths.isReady(sock) else {
                    throw HVMError.backend(.configInvalid(
                        field: "networks[\(idx)].mode",
                        reason: "socket_vmnet daemon 未就绪 (\(sock)); 请到 编辑配置 → 网络 → 安装 daemon, 或先 brew install socket_vmnet"
                    ))
                }
                // reconnect-ms=2000: socket 断开后每 2 秒自动重连. **关键**: daemon 重启
                // (--restart bootout+bootstrap) 的 1-2s 断网窗口里 QEMU 自动重连, 对 running VM 透明.
                // 去掉这个选项则任何 daemon flip 让 running VM 永久掉网.
                args += ["-netdev", "stream,id=\(netId),addr.type=unix,addr.path=\(sock),reconnect-ms=2000"]
            case .none:
                continue
            }
            args += ["-device", deviceOpts]
        }
        // ---- 显示 + 输入 ----
        // QEMU virt 默认无显卡, 必须显式加 GPU 才出 graphical UEFI/OS UI.
        // Linux: virtio-gpu-pci (内核自带 driver, OS 期 set_scanout 即可 dynamic resize)
        // Windows ARM64: 三态由 (bootFromDiskOnly, windowsDriversInstalled) 决定:
        //  - 阶段 1/2 (装机 / 装驱动): -device ramfb 单挂. 没驱动时 OS 只 enumerate "Microsoft Basic
        //    Display" 走 BDD 软件画法, 必须 ramfb 兜.
        //  - 阶段 3 (驱动装完): hvm-gpu-ramfb-pci (patches/qemu/0003 融合设备), boot 期走 ramfb 兼容
        //    EDK2/bootmgfw, OS 期 viogpudo.sys 绑 PCI 1AF4:1050 切 virtio-gpu 做 dynamic resize.
        if cfg.guestOS == .windows {
            if cfg.bootFromDiskOnly && cfg.windowsDriversInstalled {
                args += ["-device", "hvm-gpu-ramfb-pci"]
            } else {
                args += ["-device", "ramfb"]
            }
        } else {
            args += ["-device", "virtio-gpu-pci"]
        }
        // USB 键盘 + USB tablet (tablet 给绝对坐标鼠标; xhci 已在 ISO 前定义).
        args += ["-device", "usb-kbd,bus=xhci.0"]
        args += ["-device", "usb-tablet,bus=xhci.0"]
        // -display 后端: 优先 iosurface (HDP 嵌入主窗口), 否则回退 cocoa (调试用独立 NSWindow).
        if let iosurfaceSocket = inputs.iosurfaceSocketPath {
            args += ["-display", "iosurface,socket=\(iosurfaceSocket)"]
        } else {
            args += ["-display", "cocoa"]
        }

        // virtio-serial bus (vsp0): vdagent / qga / webdav 任一启用就加一条, 多 port 共用 (防重复 id + 省 PCI slot).
        let needsVirtioSerial = inputs.vdagentSocketPath != nil
                             || inputs.qgaSocketPath != nil
                             || inputs.webdavSocketPath != nil
                             || inputs.hvmClipboardSocketPath != nil
        if needsVirtioSerial {
            args += ["-device", "virtio-serial-pci,id=vsp0"]
        }
        // spice-vdagent virtio-serial 通道: guest 内 vdagent 收 EDID 变化自动改分辨率 (配合 HDP RESIZE_REQUEST).
        if let vdagentSocket = inputs.vdagentSocketPath {
            args += ["-chardev", "socket,id=vdagent,path=\(vdagentSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=vdagent,name=com.redhat.spice.0"]
        }
        // qemu-guest-agent 通路 (hvm-dbg exec-guest 跑 guest 内命令). 配套 guest 内 qemu-ga 服务.
        if let qgaSocket = inputs.qgaSocketPath {
            args += ["-chardev", "socket,id=qga,path=\(qgaSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=qga,name=org.qemu.guest_agent.0"]
        }
        // SPICE WebDAV 通路 (host ↔ guest 共享目录). chardev server=on, host 端 SpiceWebdavServer
        // 作 client 连入; guest 内 spice-webdavd 服务把 HTTP 请求复用 mux frame 转给 host.
        if let webdavSocket = inputs.webdavSocketPath {
            args += ["-chardev", "socket,id=webdav,path=\(webdavSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=webdav,name=org.spice-space.webdav.0"]
        }
        // HVM 自家 guest helper 通路. host 端 HVMFileClipboardBridge 作 client 连入,
        // guest 内 hvm-guest-helper.exe 作 server-side port; JSON length-prefix framing.
        if let hvmClipSocket = inputs.hvmClipboardSocketPath {
            args += ["-chardev", "socket,id=hvmclipboard,path=\(hvmClipSocket),server=on,wait=off"]
            args += ["-device", "virtserialport,bus=vsp0.0,chardev=hvmclipboard,name=com.hellmessage.hvm-clipboard.0"]
        }

        // ---- QMP 控制 ----
        // server=on: QEMU 监听 socket; wait=off: 不阻塞 QEMU 启动等客户端
        args += ["-qmp", "unix:\(inputs.qmpSocketPath),server=on,wait=off"]
        // 输入专用 QMP (HVMDisplayQemu.InputForwarder 用, 走 input-send-event)
        if let qmpInputSocket = inputs.qmpInputSocketPath {
            args += ["-qmp", "unix:\(qmpInputSocket),server=on,wait=off"]
        }

        // ---- Win11 TPM 2.0 (仅 windows + tpmEnabled + 调用方已启 swtpm) ----
        // swtpm daemon 由 SwtpmRunner 外部先启, socket 路径由调用方注入.
        // 没传 swtpmSocketPath 即便 tpmEnabled=true 也不挂 TPM device (调用方负责检测报错).
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
