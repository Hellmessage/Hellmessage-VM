// HVMBundle/VMConfig.swift
// config.yaml (schema v3) 的 Codable 映射.

import Foundation
import HVMCore

public enum GuestOSType: String, Codable, Sendable, CaseIterable {
    case linux
    case windows
    // macOS guest 已随 VZ 移除 (QEMU 无 Apple Silicon macOS 虚拟化路径).
}

public extension GuestOSType {
    /// 各 guestOS 默认 framebuffer 尺寸 (px) — host 侧"假定值", guest 内可改.
    /// Linux 1024x768 (text mode); Windows 1920x1080 (Win11 推荐最低).
    var defaultFramebufferSize: (width: Int, height: Int) {
        switch self {
        case .linux:   return (1024, 768)
        case .windows: return (1920, 1080)
        }
    }
}

/// 后端引擎. 仅 qemu (VZ 已移除); 保留单 case 枚举避免 schema 结构变更, 老 config 由 init(from:) 兜底 .qemu.
public enum Engine: String, Codable, Sendable, CaseIterable {
    case qemu
}

public enum DiskRole: String, Codable, Sendable {
    case main
    case data
}

/// guest framebuffer 显式尺寸 + DPI — dbg screenshot 坐标 / scanout 共用的权威尺寸.
/// 老 yaml 缺字段时 VMConfig.effectiveDisplaySpec 兜底到 GuestOSType.defaultFramebufferSize (可选, 不需 schema 升级).
public struct DisplaySpec: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// PPI: Linux/Windows guest 忽略.
    public var ppi: Int
    public init(width: Int, height: Int, ppi: Int = 220) {
        self.width = width
        self.height = height
        self.ppi = ppi
    }
}

/// 磁盘文件格式. 持久化到 config.yaml, 运行时读 disk.format 不靠扩展名推断.
///   - raw   → ftruncate sparse (仅导入的 raw 镜像)
///   - qcow2 → qemu-img create / resize
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
    /// 文件格式, 持久化到 config.yaml.
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

    /// decode 兜底: readOnly 缺 → false; format 缺 → 按 path 扩展名推断 (.qcow2 → qcow2, 其他 → raw).
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

/// 网络模式:
/// - `.user`         — QEMU 内置 user-mode (SLIRP) NAT, 零依赖
/// - `.vmnetShared`  — socket_vmnet shared (NAT+DHCP, 多 guest 互通)
/// - `.vmnetHost`    — socket_vmnet host-only (仅 host 与 guest)
/// - `.vmnetBridged` — socket_vmnet bridged (真二层桥接, 走宿主接口)
/// - `.none`         — 不挂载网卡 (`-nic none`)
///
/// 老 yaml 别名迁移 (nat→user / bridged→vmnetBridged / shared→vmnetShared) 由 NetworkSpec.init(from:) 处理.
public enum NetworkMode: String, Codable, Sendable, Equatable, CaseIterable {
    case user
    case vmnetShared
    case vmnetHost
    case vmnetBridged
    case none
}

/// QEMU NIC 设备型号
/// - virtio:  virtio-net-pci, 需 guest 驱动 (Linux 自带, Windows 需装 NetKVM)
/// - e1000e:  Intel 千兆网卡模拟, Windows ARM 自带驱动
/// - rtl8139: Realtek 老网卡, 兼容性最广性能最差, 老 guest 兜底
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
    /// QEMU NIC 设备型号. Linux 默认 virtio, Windows 默认 e1000e (开箱自带, 装 NetKVM 后可切 virtio).
    public var deviceModel: NICModel
    /// 是否启用此网卡 — false 时启动不挂, 运行中可 QMP 热插拔. 与删除区别: 禁用保留配置 (MAC/模式).
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
        // 老枚举名兼容迁移
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

    /// vmnetBridged 模式实际桥接接口名 (空时 fallback "en0"); 非 bridged 返 nil.
    public var effectiveBridgedInterface: String? {
        guard mode == .vmnetBridged else { return nil }
        if let i = bridgedInterface, !i.isEmpty { return i }
        return "en0"
    }

    /// vmnet* 模式实际 socket 路径: 显式 socketVmnetPath 优先, 否则走 SocketPaths 标准约定. 非 vmnet* 返 nil.
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

    /// QEMU 侧稳定句柄 ID (用 MAC 去冒号) — 热插拔要求添加/删除时 ID 一致.
    public var qemuStableSuffix: String? {
        guard !macAddress.isEmpty else { return nil }
        return macAddress.replacingOccurrences(of: ":", with: "").lowercased()
    }
}

/// 别名: `NetworkConfig` ≡ `NetworkSpec`.
public typealias NetworkConfig = NetworkSpec

extension NetworkSpec {
    /// 生成随机 MAC: QEMU 约定前缀 `52:54:00` + 后 3 字节随机.
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
    /// WindowsUnattend.ensureISO 生成 AutoUnattend.xml 打 ISO, windowsPE pass 跑 reg add LabConfig\Bypass*Check=1.
    /// 关掉则不挂 unattend.iso, 用户需在 Setup 里 Shift+F10 自己跑命令.
    public var bypassInstallChecks: Bool
    /// 首次登录自动从 virtio-win.iso 静默装 virtio 驱动. **当前默认 false** —
    /// UTM Guest Tools ISO 已含 ARM64 native 驱动, virtio-win.iso 不再是装机硬依赖 (QemuArgsBuilder 也已禁用 cdrom_vio).
    public var autoInstallVirtioWin: Bool
    /// 首次登录自动 NSIS /S 静默装 spice-guest-tools.exe (含 spice-vdagent). 默认 true.
    /// 走 oobeSystem pass FirstLogonCommands. 依赖 UtmGuestToolsCache 缓存; 缺失时 ensureISO fail-soft 跳过.
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

    /// 老 config 缺字段 → 默认 true 兜底; 例外: autoInstallVirtioWin → false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.secureBoot = try c.decodeIfPresent(Bool.self, forKey: .secureBoot) ?? true
        self.tpmEnabled = try c.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? true
        self.bypassInstallChecks = try c.decodeIfPresent(Bool.self, forKey: .bypassInstallChecks) ?? true
        self.autoInstallVirtioWin = try c.decodeIfPresent(Bool.self, forKey: .autoInstallVirtioWin) ?? false
        self.autoInstallSpiceTools = try c.decodeIfPresent(Bool.self, forKey: .autoInstallSpiceTools) ?? true
    }
}

/// host ↔ guest 共享目录 (SPICE WebDAV). 仅 QEMU 后端 + Linux/Windows guest 生效.
public struct SharedFolderSpec: Codable, Sendable, Equatable {
    /// host 端绝对路径. 不允许相对路径 / symlink 越界 (CLI/GUI 入口校验).
    public var hostPath: String
    /// 用户友好名, 影响 guest WebDAV root 列表. 必须 ASCII alnum + `-_`.
    public var name: String
    /// 默认 true (RO); dialog 可改 false (RW).
    public var readOnly: Bool
    /// 默认 true. 留字段供未来"挂但不自动 mount".
    public var autoMount: Bool

    public init(hostPath: String, name: String, readOnly: Bool = true, autoMount: Bool = true) {
        self.hostPath = hostPath
        self.name = name
        self.readOnly = readOnly
        self.autoMount = autoMount
    }

    private enum CodingKeys: String, CodingKey {
        case hostPath, name, readOnly, autoMount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostPath = try c.decode(String.self, forKey: .hostPath)
        self.name = try c.decode(String.self, forKey: .name)
        // 老 yaml 缺 readOnly → 默认 true (保守)
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        self.autoMount = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? true
    }

    /// sanitize 成 [a-zA-Z0-9_-]{1,32} (非允许字符 → `_`, 截断 32, 空 → "share"), 防 WebDAV URL 注入.
    public static func sanitizeName(_ raw: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var s = String(raw.map { allowed.contains($0) ? $0 : "_" })
        if s.count > 32 { s = String(s.prefix(32)) }
        if s.isEmpty { s = "share" }
        return s
    }
}

/// 整 VM 加密元信息 (schema v3). 明文 VM 缺该字段或 enabled=false.
/// 注: KDF 参数 (salt/iterations) **不**在此 — 在明文 routing JSON, 因为 config 自身可能加密了
/// (解开 config 才能读 KDF 会陷死循环). routing JSON 是跨机器 portable 入口.
public struct EncryptionSpec: Codable, Sendable, Equatable {
    /// 是否启用加密. 明文 VM = false.
    public var enabled: Bool
    /// 加密形态 (仅 enabled=true 有效). qemu-perfile: 每文件独立加密 (qcow2 LUKS / OVMF LUKS / swtpm key / config AES-GCM).
    public var scheme: EncryptionScheme?
    /// 创建时间, 仅展示
    public var createdAt: Date?

    public enum EncryptionScheme: String, Codable, Sendable, CaseIterable {
        case qemuPerfile    = "qemu-perfile"
        // vz-sparsebundle 已随 VZ 移除; 加密 VM 恒 qemu-perfile.
    }

    public init(enabled: Bool = false,
                scheme: EncryptionScheme? = nil,
                createdAt: Date? = nil) {
        self.enabled = enabled
        self.scheme = scheme
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, scheme, createdAt
    }

    /// 老 yaml 缺字段兜底: enabled → false, scheme/createdAt → nil.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.scheme = try c.decodeIfPresent(EncryptionScheme.self, forKey: .scheme)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

public struct VMConfig: Codable, Sendable, Equatable {
    /// v1 (JSON, 已断兼容) → v2 (YAML, 加 DiskSpec.format) → v3 (加顶层 encryption).
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var displayName: String
    public var guestOS: GuestOSType
    /// 后端引擎. 老 config 缺字段由 init(from:) 兜底 .qemu.
    public var engine: Engine
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskSpec]
    public var networks: [NetworkSpec]
    /// ISO 绝对路径 (不复制进 bundle). bootFromDiskOnly=true 时忽略
    public var installerISO: String?
    public var bootFromDiskOnly: Bool
    /// Windows 驱动三态切换 (仅 Windows + bootFromDiskOnly=true 生效): false 挂 ramfb 单设备;
    /// 装完 viogpudo 后切 true → 改挂 hvm-gpu-ramfb-pci 让其接管 virtio-gpu (dynamic resize / vdagent).
    public var windowsDriversInstalled: Bool
    /// host ↔ guest 剪贴板共享 (UTF-8 双向). 默认 true. 走 vdagent; 运行中可 IPC `clipboard.setEnabled` 即时切换.
    public var clipboardSharingEnabled: Bool
    /// macOS 风格快捷键: host `cmd` 当 guest `ctrl` 转发 (cmd+c → ctrl+c). 默认 true.
    /// 副作用: 失去发 Win/super 键能力. 关闭则 cmd → meta_l. GUI view-instance 级, 不持久化到 host 子进程.
    public var macStyleShortcuts: Bool
    /// guest framebuffer 显式尺寸. nil → GuestOSType.defaultFramebufferSize 兜底 (可选, 不变 schema).
    public var displaySpec: DisplaySpec?
    public var linux: LinuxSpec?
    public var windows: WindowsSpec?
    /// 加密元信息 (schema v3). nil 或 enabled=false → 明文 VM.
    public var encryption: EncryptionSpec?
    /// host ↔ guest 共享目录 (SPICE WebDAV). 仅 QEMU + Linux/Windows guest 生效. 老 yaml 缺 → [] (不需 schema 升级).
    public var sharedFolders: [SharedFolderSpec]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displayName: String,
        guestOS: GuestOSType,
        engine: Engine = .qemu,
        cpuCount: Int,
        memoryMiB: UInt64,
        disks: [DiskSpec],
        networks: [NetworkSpec] = [],
        installerISO: String? = nil,
        bootFromDiskOnly: Bool = false,
        windowsDriversInstalled: Bool = false,
        clipboardSharingEnabled: Bool = true,
        macStyleShortcuts: Bool = true,
        displaySpec: DisplaySpec? = nil,
        linux: LinuxSpec? = nil,
        windows: WindowsSpec? = nil,
        encryption: EncryptionSpec? = nil,
        sharedFolders: [SharedFolderSpec] = []
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
        self.displaySpec = displaySpec
        self.linux = linux
        self.windows = windows
        self.encryption = encryption
        self.sharedFolders = sharedFolders
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, displayName, guestOS, engine,
             cpuCount, memoryMiB, disks, networks, installerISO,
             bootFromDiskOnly, windowsDriversInstalled, clipboardSharingEnabled,
             macStyleShortcuts, displaySpec, linux, windows, encryption,
             sharedFolders
    }

    /// 自定义 decode: 给可选 / 老缺字段提供兜底默认.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.guestOS = try c.decode(GuestOSType.self, forKey: .guestOS)
        // 老 config 带 "vz" 或缺字段 → 兜底 .qemu
        self.engine = (try? c.decodeIfPresent(Engine.self, forKey: .engine) ?? .qemu) ?? .qemu
        self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        self.memoryMiB = try c.decode(UInt64.self, forKey: .memoryMiB)
        self.disks = try c.decode([DiskSpec].self, forKey: .disks)
        self.networks = try c.decodeIfPresent([NetworkSpec].self, forKey: .networks) ?? []
        self.installerISO = try c.decodeIfPresent(String.self, forKey: .installerISO)
        self.bootFromDiskOnly = try c.decodeIfPresent(Bool.self, forKey: .bootFromDiskOnly) ?? false
        // 缺字段按 bootFromDiskOnly 兜底: 老 Win VM (已在 hvm-gpu-ramfb-pci 跑) → true; 装机阶段 → false
        self.windowsDriversInstalled = try c.decodeIfPresent(Bool.self, forKey: .windowsDriversInstalled) ?? self.bootFromDiskOnly
        self.clipboardSharingEnabled = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharingEnabled) ?? true
        self.macStyleShortcuts = try c.decodeIfPresent(Bool.self, forKey: .macStyleShortcuts) ?? true
        self.displaySpec = try c.decodeIfPresent(DisplaySpec.self, forKey: .displaySpec)
        self.linux = try c.decodeIfPresent(LinuxSpec.self, forKey: .linux)
        self.windows = try c.decodeIfPresent(WindowsSpec.self, forKey: .windows)
        // 老 v2 yaml 缺 encryption → nil; ConfigMigrator v2→v3 会写入 enabled=false
        self.encryption = try c.decodeIfPresent(EncryptionSpec.self, forKey: .encryption)
        self.sharedFolders = try c.decodeIfPresent([SharedFolderSpec].self, forKey: .sharedFolders) ?? []
    }

    // MARK: - 显示尺寸权威读取

    /// 权威 framebuffer 尺寸: 优先 displaySpec, 否则按 guestOS 兜底.
    /// 所有需要 framebuffer 尺寸的地方都应走这, 不硬编码.
    public var effectiveDisplaySpec: DisplaySpec {
        if let s = displaySpec { return s }
        let fb = guestOS.defaultFramebufferSize
        return DisplaySpec(width: fb.width, height: fb.height, ppi: 220)
    }

    // MARK: - 主盘路径 helper (运行时不靠 BundleLayout 常量推断)

    /// 主盘 (role=.main) 相对 bundle 根的 path. 不存在返 nil.
    public var mainDiskRelPath: String? {
        disks.first(where: { $0.role == .main })?.path
    }

    /// 主盘绝对 URL (从 config 读).
    public func mainDiskURL(in bundle: URL) -> URL? {
        guard let rel = mainDiskRelPath else { return nil }
        return bundle.appendingPathComponent(rel)
    }

    /// 校验 engine 合法 (仅 qemu). BundleIO.save 与 hvm-cli create 主动调; Codable 不强制以保持容错.
    public func validate() throws {
        let allowed: [Engine] = [.qemu]
        guard allowed.contains(engine) else {
            throw HVMError.config(.invalidEnum(
                field: "engine",
                raw: engine.rawValue,
                allowed: allowed.map(\.rawValue)
            ))
        }
    }
}
