// VMSummary.swift
// 视图无关的 VM 概览值类型 — VMCatalog 枚举的产物.
//
// 收口 hvm-cli ListCommand.Row / 老 AppModel.VMListItem 两份各写各的列表项.
// CLI / 新 GUI store 共用同一个 summary, 不再各自解读 BundleIO / RoutingJSON.
//
// 纯 value type (Sendable + Equatable), 不引 SwiftUI / AppKit; 加密 VM 解锁前
// config 为 nil, 字段从 RoutingMetadata 兜底 (displayName / guestOS / id / scheme).

import Foundation
import HVMBundle

/// VM 运行态 (本稿二态; pause/suspend 推后跟 framebuffer / 详情页一起接).
public enum RunState: String, Sendable, Equatable {
    case stopped
    case running
}

/// 单台 VM 的视图无关概览. `config` 在加密 VM 解锁前为 nil — UI 必须兜底.
public struct VMSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let bundleURL: URL
    public let displayName: String
    public let guestOS: GuestOSType
    public let engine: Engine
    public var runState: RunState
    /// nil = 明文 VM; 非 nil = 加密 (qemuPerfile / vzSparsebundle)
    public let encryptionScheme: EncryptionSpec.EncryptionScheme?

    /// 明文 VM 持完整 config; 加密 VM 解锁前 nil. UI 详情区必须 `if let`.
    public let config: VMConfig?

    // 概览展示字段 (config 缺失时 nil → UI 显 "—"). 不含磁盘实际占用 (DiskFactory.actualBytes
    // 较慢, 列表不算; 详情页按需单独算).
    public let cpuCount: Int?
    public let memoryMiB: UInt64?
    public let mainDiskLogicalGiB: UInt64?

    public var isEncrypted: Bool { encryptionScheme != nil }

    public init(
        id: UUID,
        bundleURL: URL,
        displayName: String,
        guestOS: GuestOSType,
        engine: Engine,
        runState: RunState,
        encryptionScheme: EncryptionSpec.EncryptionScheme?,
        config: VMConfig?,
        cpuCount: Int?,
        memoryMiB: UInt64?,
        mainDiskLogicalGiB: UInt64?
    ) {
        self.id = id
        self.bundleURL = bundleURL
        self.displayName = displayName
        self.guestOS = guestOS
        self.engine = engine
        self.runState = runState
        self.encryptionScheme = encryptionScheme
        self.config = config
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.mainDiskLogicalGiB = mainDiskLogicalGiB
    }
}
