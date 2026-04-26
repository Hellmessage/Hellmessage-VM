// HVMBundle/VMConfig.swift
// config.json v1 的 Codable 映射. schema 见 docs/VM_BUNDLE.md

import Foundation

public enum GuestOSType: String, Codable, Sendable, CaseIterable {
    case macOS
    case linux
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

    private enum CodingKeys: String, CodingKey { case mode, bridgedInterface }
    private enum Raw: String { case nat, bridged }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .mode)
        switch Raw(rawValue: raw) {
        case .nat: self = .nat
        case .bridged:
            let iface = try c.decode(String.self, forKey: .bridgedInterface)
            self = .bridged(interface: iface)
        case .none:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: c,
                debugDescription: "未知 network mode: \(raw); 允许值: nat, bridged"
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

public struct VMConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var displayName: String
    public var guestOS: GuestOSType
    public var cpuCount: Int
    public var memoryMiB: UInt64
    public var disks: [DiskSpec]
    public var networks: [NetworkSpec]
    /// ISO 绝对路径 (不复制进 bundle). bootFromDiskOnly=true 时忽略
    public var installerISO: String?
    public var bootFromDiskOnly: Bool
    public var macOS: MacOSSpec?
    public var linux: LinuxSpec?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displayName: String,
        guestOS: GuestOSType,
        cpuCount: Int,
        memoryMiB: UInt64,
        disks: [DiskSpec],
        networks: [NetworkSpec] = [],
        installerISO: String? = nil,
        bootFromDiskOnly: Bool = false,
        macOS: MacOSSpec? = nil,
        linux: LinuxSpec? = nil
    ) {
        self.schemaVersion = VMConfig.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.displayName = displayName
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.disks = disks
        self.networks = networks
        self.installerISO = installerISO
        self.bootFromDiskOnly = bootFromDiskOnly
        self.macOS = macOS
        self.linux = linux
    }
}
