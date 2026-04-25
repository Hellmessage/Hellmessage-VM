// AppModel.swift
// 主 App 观察根. 维护 VM 列表、当前选中、嵌入中的 VMSession.
// @Observable (Swift 5.9+): SwiftUI view 直接读字段触发重绘.

import Foundation
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore
import HVMInstall

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
    /// 正在跑 macOS 装机时的进度. 非 nil → DialogOverlay 显示 InstallDialog 模态
    public var installState: InstallProgressState? = nil
    /// 编辑 cpu/memory 弹窗的当前 VM. 非 nil → DialogOverlay 显示 EditConfigDialog 模态
    public var editConfigItem: VMListItem? = nil

    public struct InstallProgressState: Sendable, Equatable {
        public let id: UUID
        public let displayName: String
        public var phase: Phase
        public var fraction: Double

        public enum Phase: String, Sendable, Equatable {
            case preparing, installing, finalizing
        }
    }

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
        // 自然结束(.stopped / .error) 通知 AppModel 清理列表 + 切回 stopped 卡片
        session.onEnded = { [weak self] id in
            self?.sessionDidEnd(id)
        }
        sessions[item.id] = session
        do {
            try await session.start()
        } catch {
            sessions.removeValue(forKey: item.id)
            throw error
        }
        // M2: 只嵌入主窗口, 不再独立窗口 (VZ view reparent 会导致 Metal drawable 失效)
        session.showEmbedded()
        embeddedID = item.id
        refreshList()
    }

    public func stop(_ id: UUID) throws {
        guard let s = sessions[id] else { return }
        try s.requestStop()
    }

    public func pause(_ id: UUID) async throws {
        guard let s = sessions[id] else { return }
        try await s.pause()
    }

    public func resume(_ id: UUID) async throws {
        guard let s = sessions[id] else { return }
        try await s.resume()
    }

    public func kill(_ id: UUID) async throws {
        guard let s = sessions[id] else { return }
        try await s.forceStop()
        // 不在此处 sessions.removeValue + refreshList:
        // forceStop 走完时, state observer 的 Task { @MainActor in onStateChanged(.stopped) }
        // 还没派发. 若此处 removeValue, 唯一的 local 强引用 s 出 scope 后 VMSession 立即 dealloc,
        // observer 的 [weak self] 失效, cleanup() / onEnded 都不会跑, BundleLock 只能靠
        // BundleLock.deinit 兜底释放 — 而那时 refreshList 已经读过 isBusy=true (同进程 fcntl
        // flock 互斥) 把 runState 写成 running, sidebar 卡死.
        // 让 sessions / list 收尾走 VMSession.onStateChanged -> cleanup -> onEnded -> sessionDidEnd
        // 这条统一路径: cleanup 同步释放 lock, sessionDidEnd 的 refreshList 读到 busy=false.
    }

    // MARK: - macOS guest 装机

    /// 跑 VZMacOSInstaller 流程. 进度更新 self.installState, DialogOverlay 监听显示.
    /// 完成后自动 refreshList; 失败走 errors.present 标准错误弹窗.
    public func startInstall(
        bundleURL: URL,
        config: VMConfig,
        ipswURL: URL,
        errors: ErrorPresenter
    ) {
        installState = InstallProgressState(
            id: config.id,
            displayName: config.displayName,
            phase: .preparing,
            fraction: 0
        )
        Task { @MainActor [weak self] in
            let installer = MacInstaller()
            do {
                try await installer.install(
                    bundleURL: bundleURL,
                    config: config,
                    ipswURL: ipswURL
                ) { progress in
                    guard let self else { return }
                    switch progress {
                    case .preparing:
                        self.installState?.phase = .preparing
                    case .installing(let f):
                        self.installState?.phase = .installing
                        self.installState?.fraction = f
                    case .finalizing:
                        self.installState?.phase = .finalizing
                    }
                }
                self?.installState = nil
                self?.refreshList()
            } catch {
                self?.installState = nil
                errors.present(error)
                self?.refreshList()
            }
        }
    }

    /// session 自然结束时通知 (guestDidStop / error) -> 从 sessions 移除
    public func sessionDidEnd(_ id: UUID) {
        sessions.removeValue(forKey: id)
        if embeddedID == id { embeddedID = nil }
        refreshList()
    }

    // MARK: - 嵌入 (M2 唯一显示模式)

    public func embedInMain(_ id: UUID) {
        guard let s = sessions[id] else { return }
        s.showEmbedded()
        embeddedID = id
    }
}
