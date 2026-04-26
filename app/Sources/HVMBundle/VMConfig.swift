// HVMBundle/VMConfig.swift
// config.json v1 的 Codable 映射. schema 见 docs/VM_BUNDLE.md

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

public struct DiskSpec: Codable, Sendable, Equatable {
    public var role: DiskRole
    /// 相对 bundle root 的路径 (例 "disks/main.img")
    public var path: String
    public var sizeGiB: UInt64
    public var readOnly: Bool

    public init(role: DiskRole, path: String, sizeGiB: UInt64, readOnly: Bool = false) {
        self.role = role
        self.path = path
        self.sizeGiB = sizeGiB
        self.readOnly = readOnly
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

    public init(secureBoot: Bool = true, tpmEnabled: Bool = true) {
        self.secureBoot = secureBoot
        self.tpmEnabled = tpmEnabled
    }
}

public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

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
