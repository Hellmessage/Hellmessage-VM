// AppModel.swift
// 主 App 观察根. 维护 VM 列表、当前选中、嵌入中的 VMSession.
// @Observable (Swift 5.9+): SwiftUI view 直接读字段触发重绘.

import Foundation
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore

@MainActor
@Observable
public final class AppModel {
    public struct VMListItem: Identifiable, Sendable {
        public let id: UUID
        public let bundleURL: URL
        public let displayName: String
        public let guestOS: GuestOSType
        public let config: VMConfig
        public var runState: String   // "stopped" / "running" (推断, GUI 内实时用 session)

        public init(bundleURL: URL, config: VMConfig, runState: String) {
            self.id = config.id
            self.bundleURL = bundleURL
            self.displayName = config.displayName
            self.guestOS = config.guestOS
            self.config = config
            self.runState = runState
        }
    }

    public var list: [VMListItem] = []
    public var selectedID: UUID?
    /// 当前 GUI 进程内运行中的 VM, 按 config.id 索引
    public var sessions: [UUID: VMSession] = [:]
    /// 当前嵌入主窗口右栏展示的 VM (同时只有一个)
    public var embeddedID: UUID?
    /// 创建向导显隐
    public var showCreateWizard: Bool = false

    public init() {}

    // MARK: - 列表管理

    public func refreshList() {
        let root = HVMPaths.vmsRoot
        let urls = (try? BundleDiscovery.list(in: root)) ?? []
        var items: [VMListItem] = []
        for u in urls {
            guard let cfg = try? BundleIO.load(from: u) else { continue }
            let busy = BundleLock.isBusy(bundleURL: u)
            items.append(VMListItem(bundleURL: u, config: cfg,
                                    runState: busy ? "running" : "stopped"))
        }
        self.list = items.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

        // 选中项若已不存在, 清选
        if let sel = selectedID, !list.contains(where: { $0.id == sel }) {
            selectedID = list.first?.id
        } else if selectedID == nil {
            selectedID = list.first?.id
        }
    }

    public var selectedItem: VMListItem? {
        guard let sel = selectedID else { return nil }
        return list.first { $0.id == sel }
    }

    public var selectedSession: VMSession? {
        guard let sel = selectedID else { return nil }
        return sessions[sel]
    }

    // MARK: - VM 控制

    public func start(_ item: VMListItem) async throws {
        if sessions[item.id] != nil { return }
        let session = VMSession(bundleURL: item.bundleURL, config: item.config)
        sessions[item.id] = session
        do {
            try await session.start()
        } catch {
            sessions.removeValue(forKey: item.id)
            throw error
        }
        // 默认独立窗口态 (docs/GUI.md: "运行中的 VM 默认打开独立窗口")
        session.showStandalone()
        refreshList()
    }

    public func stop(_ id: UUID) throws {
        guard let s = sessions[id] else { return }
        try s.requestStop()
    }

    public func kill(_ id: UUID) async throws {
        guard let s = sessions[id] else { return }
        try await s.forceStop()
        sessions.removeValue(forKey: id)
        if embeddedID == id { embeddedID = nil }
        refreshList()
    }

    /// session 自然结束时通知 (guestDidStop / error) -> 从 sessions 移除
    public func sessionDidEnd(_ id: UUID) {
        sessions.removeValue(forKey: id)
        if embeddedID == id { embeddedID = nil }
        refreshList()
    }

    // MARK: - 嵌入切换

    public func embedInMain(_ id: UUID) {
        guard let s = sessions[id] else { return }
        // 取消旧的嵌入
        if let oldID = embeddedID, oldID != id, let old = sessions[oldID] {
            old.showStandalone()
        }
        s.showEmbedded()
        embeddedID = id
    }

    public func popOutStandalone(_ id: UUID) {
        guard let s = sessions[id] else { return }
        if embeddedID == id { embeddedID = nil }
        s.showStandalone()
    }
}
