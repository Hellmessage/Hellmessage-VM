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

public enum NetworkMode: Codable, Sendable, Equatable {
    case nat
    case bridged(interface: String)
    /// QEMU socket_vmnet --vmnet-mode shared: NAT 内网, host 与 guest 互通,
    /// guest 之间也互通, 但出口流量走 host 共享地址段 (与 .nat 区别在于多 guest 互通)
    case shared

    private enum CodingKeys: String, CodingKey { case mode, bridgedInterface }
    private enum Raw: String { case nat, bridged, shared }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .mode)
        switch Raw(rawValue: raw) {
        case .nat: self = .nat
        case .bridged:
            let iface = try c.decode(String.self, forKey: .bridgedInterface)
            self = .bridged(interface: iface)
        case .shared: self = .shared
        case .none:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: c,
                debugDescription: "未知 network mode: \(raw); 允许值: nat, bridged, shared"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nat:
            try c.encode(Raw.nat.rawValue, forKey: .mode)
        case .bridged(let iface):
            try c.encode(Raw.bridged.rawValue, forKey: .mode)
            try c.encode(iface, forKey: .bridgedInterface)
        case .shared:
            try c.encode(Raw.shared.rawValue, forKey: .mode)
        }
    }
}

public struct NetworkSpec: Codable, Sendable, Equatable {
    public var mode: NetworkMode
    /// MAC 地址 (小写冒号分隔), 缺省时生成时填入, 持久化
    public var macAddress: String

    private enum CodingKeys: String, CodingKey { case mode, bridgedInterface, macAddress }

    public init(mode: NetworkMode, macAddress: String) {
        self.mode = mode
        self.macAddress = macAddress
    }

    public init(from decoder: Decoder) throws {
        self.mode = try NetworkMode(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.macAddress = try c.decode(String.self, forKey: .macAddress)
    }

    public func encode(to encoder: Encoder) throws {
        try mode.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(macAddress, forKey: .macAddress)
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
    /// 默认 true. 走 oobeSystem pass 的 FirstLogonCommands 跑 certutil + pnputil /add-driver /subdirs /install.
    /// 关掉则用户需进系统后手动从 virtio-win cdrom 装驱动.
    public var autoInstallVirtioWin: Bool
    /// 装完 Windows 后首次登录自动 NSIS /S 静默装 spice-guest-tools.exe (含 spice-vdagent 服务).
    /// 默认 true. 走 oobeSystem pass FirstLogonCommands 找 unattend ISO 上的 .exe 跑 /S 装.
    /// 装完后 host 拖 HVM 主窗口 → guest 自动改分辨率 (vdagent 响应 monitor config 协议).
    /// 关掉则 user 需进系统后手动跑 spice-guest-tools-latest.exe.
    /// 依赖 SpiceToolsCache 已下载到全局缓存; 缓存缺失时 ensureISO fail-soft 跳过 (warn).
    public var autoInstallSpiceTools: Bool

    public init(secureBoot: Bool = true, tpmEnabled: Bool = true,
                bypassInstallChecks: Bool = true, autoInstallVirtioWin: Bool = true,
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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.secureBoot = try c.decodeIfPresent(Bool.self, forKey: .secureBoot) ?? true
        self.tpmEnabled = try c.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? true
        self.bypassInstallChecks = try c.decodeIfPresent(Bool.self, forKey: .bypassInstallChecks) ?? true
        self.autoInstallVirtioWin = try c.decodeIfPresent(Bool.self, forKey: .autoInstallVirtioWin) ?? true
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
        self.macOS = macOS
        self.linux = linux
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, displayName, guestOS, engine,
             cpuCount, memoryMiB, disks, networks, installerISO,
             bootFromDiskOnly, macOS, linux, windows
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
