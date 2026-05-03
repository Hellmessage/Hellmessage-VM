// HVMBundle/VMConfig.swift
// config.yaml schema v2 的 Codable 映射. schema 见 docs/VM_BUNDLE.md
// schema 历史:
//   v1 (.json): 老格式, 已断兼容, 不再读取
//   v2 (.yaml): 当前. DiskSpec 加 format 字段 (raw/qcow2)

import Foundation
import HVMCore

public enum GuestOSType: String, Codable, Sendable, CaseIterable {
    case macOS
    case linux
    case windows
}

public extension GuestOSType {
    /// 各 guestOS 的默认 framebuffer 尺寸 (px). VZ 离屏 window / QEMU 鼠标 abs 映射 / dbg
    /// status 都用这个估算; 实际尺寸 guest 内可改, 这只是 host 侧的"假定值".
    /// 决策:
    ///   - Linux: 1024x768 — text mode + 早期 X / Wayland session 默认
    ///   - macOS: 1920x1080 — VZMacGraphicsDisplayConfiguration 我们硬编码 1080p
    ///   - Windows: 1920x1080 — Win11 推荐最低, 用同 macOS 尺寸保持一致
    var defaultFramebufferSize: (width: Int, height: Int) {
        switch self {
        case .linux:   return (1024, 768)
        case .macOS, .windows: return (1920, 1080)
        }
    }
}

/// 后端引擎. macOS 仅 vz; Linux 二选一; Windows 仅 qemu (CLAUDE.md 约束).
/// 老 v1 config 缺该字段时, VMConfig.init(from:) 兜底为 .vz, 不需要 schema 迁移.
public enum Engine: String, Codable, Sendable, CaseIterable {
    case vz
    case qemu
}

public enum DiskRole: String, Codable, Sendable {
    case main
    case data
}

/// 磁盘文件格式. 持久化到 config.yaml, 运行时读 disk.format 不再靠扩展名推断.
///   - raw   → ftruncate sparse, VZ 后端必走
///   - qcow2 → qemu-img create / resize, QEMU 后端走
public enum DiskFormat: String, Codable, Sendable, CaseIterable {
    case raw
    case qcow2
}

public struct DiskSpec: Codable, Sendable, Equatable {
    public var role: DiskRole
    /// 相对 bundle root 的路径 (例 "disks/os.img" 或 "disks/os.qcow2")
    public var path: String
    public var sizeGiB: UInt64
    public var readOnly: Bool
    /// 文件格式. 创建时按 engine 决定 (vz=raw, qemu=qcow2), 持久化到 config.yaml.
    public var format: DiskFormat

    public init(role: DiskRole, path: String, sizeGiB: UInt64, format: DiskFormat, readOnly: Bool = false) {
        self.role = role
        self.path = path
        self.sizeGiB = sizeGiB
        self.format = format
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case role, path, sizeGiB, format, readOnly
    }

    /// decode 兜底:
    ///   - readOnly 缺 → false
    ///   - format 缺 → 按 path 扩展名推断 (.qcow2 → qcow2, 其他 → raw),
    ///     仅适用 ConfigMigrator v1→v2 临时桥接 (.json 已断兼容,
    ///     正常情况下 yaml 一定带 format 字段)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(DiskRole.self, forKey: .role)
        self.path = try c.decode(String.self, forKey: .path)
        self.sizeGiB = try c.decode(UInt64.self, forKey: .sizeGiB)
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        if let fmt = try c.decodeIfPresent(DiskFormat.self, forKey: .format) {
            self.format = fmt
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            self.format = (ext == "qcow2") ? .qcow2 : .raw
        }
    }
}

/// 网络模式 (与 hell-vm `NetworkConfig.Mode` 一致):
/// - `.user`         — QEMU 内置 user-mode (SLIRP) NAT / VZ NAT, 零依赖
/// - `.vmnetShared`  — socket_vmnet shared (NAT+DHCP, 多 guest 互通)
/// - `.vmnetHost`    — socket_vmnet host-only (仅 host 与 guest)
/// - `.vmnetBridged` — socket_vmnet bridged (真二层桥接, 走宿主接口)
/// - `.none`         — 不挂载网卡 (`-nic none`)
///
/// Codable rawValue = String, 老 yaml 兼容: `nat→user / bridged→vmnetBridged /
/// shared→vmnetShared` 由 NetworkSpec.init(from:) 拦下做迁移.
public enum NetworkMode: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case vmnetShared
    case vmnetHost
    case vmnetBridged
    case none
}

/// QEMU NIC 设备型号
/// - virtio:  virtio-net-pci, 需 guest 驱动 (Linux 自带, Windows 需装 NetKVM)
/// - e1000e:  Intel 千兆网卡模拟, Windows ARM / macOS 自带驱动
/// - rtl8139: Realtek 老网卡, 兼容性最广但性能最差, 老 guest 兜底
public enum NICModel: String, Codable, Sendable, CaseIterable {
    case virtio
    case e1000e
    case rtl8139

    /// 翻译成 QEMU `-device` 参数名
    public var qemuDeviceName: String {
        switch self {
        case .virtio:  return "virtio-net-pci"
        case .e1000e:  return "e1000e"
        case .rtl8139: return "rtl8139"
        }
    }
}

public struct NetworkSpec: Codable, Sendable, Equatable {
    public var mode: NetworkMode
    /// MAC 地址 (小写冒号分隔), 缺省时生成时填入, 持久化
    public var macAddress: String
    /// socket_vmnet unix socket 路径 (仅 vmnet* 模式用, 留空则按 mode 取默认 SocketPaths.*)
    public var socketVmnetPath: String?
    /// vmnetBridged 模式要桥接的宿主网卡 (如 "en0"), 其它模式忽略
    public var bridgedInterface: String?
    /// QEMU NIC 设备型号. Linux 默认 virtio (自带驱动), Windows 默认 e1000e
    /// (Windows ARM 开箱自带 e1000e 驱动; 装 NetKVM/viogpudo 后可切 virtio 更快).
    public var deviceModel: NICModel
    /// 是否启用此网卡 — false 时启动不挂, 运行中可通过 QMP 热插拔 attach/detach.
    /// 与删除区别: 禁用保留配置 (MAC/模式), 后续再启用恢复同样 NIC 身份.
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case mode, macAddress, socketVmnetPath, bridgedInterface, deviceModel, enabled
    }

    public init(
        mode: NetworkMode,
        macAddress: String,
        socketVmnetPath: String? = nil,
        bridgedInterface: String? = nil,
        deviceModel: NICModel = .virtio,
        enabled: Bool = true
    ) {
        self.mode = mode
        self.macAddress = macAddress
        self.socketVmnetPath = socketVmnetPath
        self.bridgedInterface = bridgedInterface
        self.deviceModel = deviceModel
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 老枚举名兼容: nat → user, bridged → vmnetBridged, shared → vmnetShared
        let raw = try c.decode(String.self, forKey: .mode)
        switch raw {
        case "user", "nat":             self.mode = .user
        case "vmnetShared", "shared":   self.mode = .vmnetShared
        case "vmnetHost", "hostOnly":   self.mode = .vmnetHost
        case "vmnetBridged", "bridged": self.mode = .vmnetBridged
        case "none":                    self.mode = .none
        default:                        self.mode = .user   // 未知值兜底为 user
        }
        self.macAddress       = try c.decode(String.self, forKey: .macAddress)
        self.socketVmnetPath  = try c.decodeIfPresent(String.self, forKey: .socketVmnetPath)
        self.bridgedInterface = try c.decodeIfPresent(String.self, forKey: .bridgedInterface)
        self.deviceModel      = try c.decodeIfPresent(NICModel.self, forKey: .deviceModel) ?? .virtio
        self.enabled          = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 对 vmnetBridged 模式, 推导实际使用的桥接接口名.
    /// `bridgedInterface` 为空时 fallback 到 "en0" (历史行为, 兼容 hell-vm).
    /// 非 bridged 模式返回 nil.
    public var effectiveBridgedInterface: String? {
        guard mode == .vmnetBridged else { return nil }
        if let i = bridgedInterface, !i.isEmpty { return i }
        return "en0"
    }

    /// 推导实际使用的 socket 路径 (vmnet* 模式): 用户显式填 socketVmnetPath 优先,
    /// 否则走 SocketPaths 集中的标准约定. 非 vmnet* 模式返回 nil.
    public var effectiveSocketPath: String? {
        if let p = socketVmnetPath, !p.isEmpty { return p }
        switch mode {
        case .vmnetShared:  return SocketPaths.vmnetShared
        case .vmnetHost:    return SocketPaths.vmnetHost
        case .vmnetBridged:
            let iface = effectiveBridgedInterface ?? "en0"
            return SocketPaths.vmnetBridged(interface: iface)
        case .user, .none:  return nil
        }
    }

    /// QEMU 侧稳定 ID — 热插拔要求添加/删除时 ID 一致. 用 MAC 去冒号做后缀,
    /// guest 看到的仍然是 NIC 顺序, 这里只是 host 端 QEMU 的内部句柄名.
    public var qemuStableSuffix: String? {
        guard !macAddress.isEmpty else { return nil }
        return macAddress.replacingOccurrences(of: ":", with: "").lowercased()
    }
}

/// hell-vm 风格别名: `NetworkConfig` ≡ `NetworkSpec`. 抄过来的 UI / hotplug 代码
/// 直接用 NetworkConfig 名字也能编译.
public typealias NetworkConfig = NetworkSpec

extension NetworkSpec {
    /// 生成一个 locally-administered + unicast 的随机 MAC 地址.
    /// OUI 固定用 QEMU 约定前缀 `52:54:00`, 后 3 字节随机.
    public static func generateRandomMAC() -> String {
        let tail = (0..<3).map { _ in UInt8.random(in: 0...255) }
        return String(format: "52:54:00:%02x:%02x:%02x", tail[0], tail[1], tail[2])
    }

    /// 简单校验 MAC 字符串合法性 (6 组十六进制, 冒号分隔, 大小写不限)
    public static func isValidMAC(_ s: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct MacOSSpec: Codable, Sendable, Equatable {
    public var ipsw: String?
    public var autoInstalled: Bool

    public init(ipsw: String? = nil, autoInstalled: Bool = false) {
        self.ipsw = ipsw
        self.autoInstalled = autoInstalled
    }
}

public struct LinuxSpec: Codable, Sendable, Equatable {
    public var kernelCmdLineExtra: String?
    public var rosettaShare: Bool

    public init(kernelCmdLineExtra: String? = nil, rosettaShare: Bool = false) {
        self.kernelCmdLineExtra = kernelCmdLineExtra
        self.rosettaShare = rosettaShare
    }
}

public struct WindowsSpec: Codable, Sendable, Equatable {
    /// Secure Boot 启用 (Win11 强制要求, 默认 true)
    public var secureBoot: Bool
    /// TPM 2.0 启用 (Win11 强制要求, 默认 true; QEMU 通过 swtpm unix socket 提供)
    public var tpmEnabled: Bool
    /// 跳过 Win11 Setup 硬件检查 (TPM/SecureBoot/RAM/CPU/Storage). 默认 true.
    /// 实现路径: WindowsUnattend.ensureISO 生成 AutoUnattend.xml + hdiutil makehybrid 打 ISO,
    /// 启动时挂第二个 cdrom; windowsPE pass 跑 reg add LabConfig\Bypass*Check=1.
    /// 关掉则不挂 unattend.iso, 用户需要在 Setup 里按 Shift+F10 自己跑命令.
    public var bypassInstallChecks: Bool
    /// 装完 Windows 后首次登录自动从 virtio-win.iso 静默装 virtio 驱动 (NetKVM/viostor/viogpudo).
    /// **当前默认 false** — UTM Guest Tools ISO 已含 ARM64 native 驱动 (NetKVM/viostor/viogpudo
    /// + qemu-ga), virtio-win.iso 不再是 Win VM 装机硬依赖. QemuArgsBuilder 也已禁用 cdrom_vio
    /// 挂载 (即便此字段为 true). 后续若要恢复老 virtio-win.iso 通路, 同时改这里 default + 解除
    /// QemuArgsBuilder 的 `if false` + 重新打开 CreateVMDialog 的 startVirtioWinFetch 触发.
    /// 走 oobeSystem pass 的 FirstLogonCommands 跑 certutil + pnputil /add-driver /subdirs /install.
    public var autoInstallVirtioWin: Bool
    /// 装完 Windows 后首次登录自动 NSIS /S 静默装 spice-guest-tools.exe (含 spice-vdagent 服务).
    /// 默认 true. 走 oobeSystem pass FirstLogonCommands 找 unattend ISO 上的 .exe 跑 /S 装.
    /// 装完后 host 拖 HVM 主窗口 → guest 自动改分辨率 (vdagent 响应 monitor config 协议).
    /// 关掉则 user 需进系统后手动跑 spice-guest-tools-latest.exe.
    /// 依赖 UtmGuestToolsCache 已下载到全局缓存; 缓存缺失时 ensureISO fail-soft 跳过 (warn).
    public var autoInstallSpiceTools: Bool

    public init(secureBoot: Bool = true, tpmEnabled: Bool = true,
                bypassInstallChecks: Bool = true, autoInstallVirtioWin: Bool = false,
                autoInstallSpiceTools: Bool = true) {
        self.secureBoot = secureBoot
        self.tpmEnabled = tpmEnabled
        self.bypassInstallChecks = bypassInstallChecks
        self.autoInstallVirtioWin = autoInstallVirtioWin
        self.autoInstallSpiceTools = autoInstallSpiceTools
    }

    private enum CodingKeys: String, CodingKey {
        case secureBoot, tpmEnabled, bypassInstallChecks, autoInstallVirtioWin, autoInstallSpiceTools
    }

    /// 老 config (新增字段前) 缺字段 → 默认 true 兜底.
    /// 例外: autoInstallVirtioWin 缺字段 → false (UTM Guest Tools 已替代 virtio-win.iso,
    /// 老 VM 也无须再走 pnputil 段).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.secureBoot = try c.decodeIfPresent(Bool.self, forKey: .secureBoot) ?? true
        self.tpmEnabled = try c.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? true
        self.bypassInstallChecks = try c.decodeIfPresent(Bool.self, forKey: .bypassInstallChecks) ?? true
        self.autoInstallVirtioWin = try c.decodeIfPresent(Bool.self, forKey: .autoInstallVirtioWin) ?? false
        self.autoInstallSpiceTools = try c.decodeIfPresent(Bool.self, forKey: .autoInstallSpiceTools) ?? true
    }
}

public struct VMConfig: Codable, Sendable, Equatable {
    /// schema v1: JSON, DiskSpec 无 format 字段 (已断兼容, 不再读)
    /// schema v2: YAML, DiskSpec 加 format (raw / qcow2)
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var displayName: String
    public var guestOS: GuestOSType
    /// 后端引擎. 老 v1 config 缺该字段时由 init(from:) 兜底 .vz, 不需要 schema 迁移
    public var engine: Engine
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskSpec]
    public var networks: [NetworkSpec]
    /// ISO 绝对路径 (不复制进 bundle). bootFromDiskOnly=true 时忽略
    public var installerISO: String?
    public var bootFromDiskOnly: Bool
    /// Windows 三态切换: 仅 Windows + bootFromDiskOnly=true 才生效, 装完 OS 还没装 viogpudo 时
    /// false → QemuArgsBuilder 仍挂 ramfb 单设备; 用户在 guest 内装完驱动手动切 true →
    /// 改挂 hvm-gpu-ramfb-pci 让 viogpudo 接管 virtio-gpu 通路 (dynamic resize / vdagent).
    /// Linux/macOS 字段忽略.
    public var windowsDriversInstalled: Bool
    /// host ↔ guest 剪贴板共享开关 (UTF-8 文本, 双向). 默认 true.
    /// 仅 QEMU 后端生效 (走 vdagent virtio-serial chardev); VZ 后端的 macOS guest VZ 框架
    /// 自带剪贴板, 这字段忽略. 运行中可通过 IPC `clipboard.setEnabled` 即时切换 (不必重启 VM).
    public var clipboardSharingEnabled: Bool
    /// macOS 风格快捷键: host `cmd` 当 guest `ctrl` 转发 (cmd+c → ctrl+c 等). 默认 true.
    /// 仅 QEMU 后端 (Win/Linux guest) 生效, VZ macOS guest 忽略此字段.
    /// 副作用: 开启后失去发 Win/super 键的能力 (用鼠标点开始菜单代替).
    /// 关闭后行为退回老逻辑: cmd → meta_l (Win 键), 用户用 control+c 复制.
    /// GUI 进程内 view-instance 级开关, 不持久化到 host 子进程 — 改完无须重启 VM, 关掉编辑面板生效.
    public var macStyleShortcuts: Bool
    public var macOS: MacOSSpec?
    public var linux: LinuxSpec?
    public var windows: WindowsSpec?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displayName: String,
        guestOS: GuestOSType,
        engine: Engine = .vz,
        cpuCount: Int,
        memoryMiB: UInt64,
        disks: [DiskSpec],
        networks: [NetworkSpec] = [],
        installerISO: String? = nil,
        bootFromDiskOnly: Bool = false,
        windowsDriversInstalled: Bool = false,
        clipboardSharingEnabled: Bool = true,
        macStyleShortcuts: Bool = true,
        macOS: MacOSSpec? = nil,
        linux: LinuxSpec? = nil,
        windows: WindowsSpec? = nil
    ) {
        self.schemaVersion = VMConfig.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.displayName = displayName
        self.guestOS = guestOS
        self.engine = engine
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.disks = disks
        self.networks = networks
        self.installerISO = installerISO
        self.bootFromDiskOnly = bootFromDiskOnly
        self.windowsDriversInstalled = windowsDriversInstalled
        self.clipboardSharingEnabled = clipboardSharingEnabled
        self.macStyleShortcuts = macStyleShortcuts
        self.macOS = macOS
        self.linux = linux
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, displayName, guestOS, engine,
             cpuCount, memoryMiB, disks, networks, installerISO,
             bootFromDiskOnly, windowsDriversInstalled, clipboardSharingEnabled,
             macStyleShortcuts, macOS, linux, windows
    }

    /// 自定义 decode: 仅为 engine 字段提供"缺省 .vz"兜底, 其他字段沿用合成默认行为
    /// (老 v1 config.json 没有 engine 字段, 直接 decode 出 .vz; encode 时正常写出)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.guestOS = try c.decode(GuestOSType.self, forKey: .guestOS)
        self.engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .vz
        self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        self.memoryMiB = try c.decode(UInt64.self, forKey: .memoryMiB)
        self.disks = try c.decode([DiskSpec].self, forKey: .disks)
        self.networks = try c.decodeIfPresent([NetworkSpec].self, forKey: .networks) ?? []
        self.installerISO = try c.decodeIfPresent(String.self, forKey: .installerISO)
        self.bootFromDiskOnly = try c.decodeIfPresent(Bool.self, forKey: .bootFromDiskOnly) ?? false
        // 老存量 yaml 没该字段时按 bootFromDiskOnly 兜底:
        //   - 老 Windows VM 已经在 hvm-gpu-ramfb-pci 跑 (bootFromDiskOnly=true) → 默认 true 不回退到 ramfb
        //   - 装机阶段 (false) → 默认 false 跟新建 VM 一致
        self.windowsDriversInstalled = try c.decodeIfPresent(Bool.self, forKey: .windowsDriversInstalled) ?? self.bootFromDiskOnly
        // 老 yaml 缺字段 → 默认 true (符合"开箱可用, 用户没显式关就开"的预期)
        self.clipboardSharingEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharingEnabled) ?? true
        self.macStyleShortcuts = try c.decodeIfPresent(Bool.self, forKey: .macStyleShortcuts) ?? true
        self.macOS = try c.decodeIfPresent(MacOSSpec.self, forKey: .macOS)
        self.linux = try c.decodeIfPresent(LinuxSpec.self, forKey: .linux)
        self.windows = try c.decodeIfPresent(WindowsSpec.self, forKey: .windows)
    }

    // MARK: - 主盘路径 helper (运行时不要用 BundleLayout.mainDiskName 之类常量推断)

    /// 主盘 (role=.main) 的 path (相对 bundle 根的路径). 不存在时返 nil.
    public var mainDiskRelPath: String? {
        disks.first(where: { $0.role == .main })?.path
    }

    /// 主盘绝对 URL (从 config 读, 不依赖 BundleLayout 常量).
    public func mainDiskURL(in bundle: URL) -> URL? {
        guard let rel = mainDiskRelPath else { return nil }
        return bundle.appendingPathComponent(rel)
    }

    /// 校验 engine 与 guestOS 的合法组合 (CLAUDE.md「支持的 Guest OS 约束」).
    /// BundleIO.save 与 hvm-cli create 应主动调用; Codable 本身不强制以保持容错.
    public func validate() throws {
        let allowed: [Engine]
        switch guestOS {
        case .macOS:   allowed = [.vz]            // VZMacOSInstaller 路径, QEMU 跑不了 macOS
        case .linux:   allowed = [.vz, .qemu]     // 双后端
        case .windows: allowed = [.qemu]          // VZ 无 TPM, QEMU 唯一选择
        }
        guard allowed.contains(engine) else {
            throw HVMError.config(.invalidEnum(
                field: "engine",
                raw: engine.rawValue,
                allowed: allowed.map(\.rawValue)
            ))
        }
    }
}
