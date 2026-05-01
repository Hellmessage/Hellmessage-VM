// AppModel.swift
// 主 App 观察根. 维护 VM 列表、当前选中、嵌入中的 VMSession.
// @Observable (Swift 5.9+): SwiftUI view 直接读字段触发重绘.

import Foundation
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore
import HVMInstall
import HVMIPC
import HVMDisplayQemu

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
    /// refreshList 的 mtime 缓存: bundlePath → (config.json mtime, item).
    /// mtime 没变直接复用 item, 避免每次 popover/tab 切换都全量 BundleIO.load + flock 探测.
    private var refreshCache: [String: (mtime: Date, item: VMListItem)] = [:]
    /// 当前嵌入主窗口右栏展示的 VM (同时只有一个)
    public var embeddedID: UUID?
    /// QEMU 后端 VM 的 fanout session 缓存. 一个 VM 一个, 由主窗口嵌入路径或
    /// detached 独立窗口需要 framebuffer 时 lazy 创建; 当所有 subscriber 都
    /// 注销 (主窗口切走 + 独立窗口关闭) 时 tearDown.
    /// 跟 sessions[] 平行: sessions 是 VZ 通路的本进程 VZVirtualMachine,
    /// qemuFanouts 是 QEMU 通路的 host 子进程 framebuffer 扇出.
    /// internal: QemuFanoutSession 类型本身 internal, 没必要跨模块暴露.
    var qemuFanouts: [UUID: QemuFanoutSession] = [:]
    /// GUI 端 control IPC server (per VM, 路径 guiControlSocketPath). hvm-dbg
    /// display-resize 通过它 trigger fanout.fireResize, 自动化测试 resize 链路.
    /// ensureQemuFanout 时启, tearDownQemuFanout 时停; 跟 fanout 同生命周期.
    @ObservationIgnored
    var qemuGUIServers: [UUID: SocketServer] = [:]
    /// QEMU 后端 VM 当前已弹出的独立窗口 (共存式: 主窗口嵌入仍可同时存在).
    /// 用 detachedQemuVMs 集合给 SwiftUI 订阅状态变化以更新 detach 按钮 UI;
    /// 真正持有 controller 的是 detachedQemuWindowControllers (非 @Observable
    /// 字段, 避免 SwiftUI 订阅 NSWindowController 这种非 Sendable 引用).
    public var detachedQemuVMs: Set<UUID> = []
    @ObservationIgnored
    var detachedQemuWindowControllers: [UUID: DetachedVMWindowController] = [:]
    /// 由 HVMAppDelegate 在应用启动时注入的 errors / confirms 引用. 独立窗口
    /// (detached) 里 BottomBar 的 stop/kill 等操作复用主进程同一份 presenter,
    /// 错误弹窗仍出现在主窗口的 DialogOverlay (而不是 detached 窗口里).
    @ObservationIgnored
    public weak var sharedErrors: ErrorPresenter?
    /// 创建向导显隐
    public var showCreateWizard: Bool = false
    /// 正在跑 macOS 装机时的进度. 非 nil → DialogOverlay 显示 InstallDialog 模态
    public var installState: InstallProgressState? = nil
    /// 正在拉 IPSW 时的进度. 非 nil → DialogOverlay 显示 IpswFetchDialog 模态
    public var ipswFetchState: IpswFetchState? = nil
    /// 正在拉 virtio-win.iso 时的进度. 非 nil → DialogOverlay 显示 VirtioWinFetchDialog 模态
    public var virtioWinFetchState: VirtioWinFetchState? = nil
    /// IPSW 版本选择器是否打开. 非 nil → DialogOverlay 显示 IpswCatalogPicker 模态.
    /// 选完后通过 onSelect 回调把 entry 交回上层 (向导)
    public var ipswCatalogPicker: IpswCatalogPickerState? = nil

    /// IPSW catalog picker 状态, 含选完的回调.
    /// 用 @MainActor 闭包让 picker 直接通过 model 触发 startIpswFetch.
    public struct IpswCatalogPickerState {
        public let onSelect: @MainActor (IPSWCatalogEntry) -> Void
        public init(onSelect: @escaping @MainActor (IPSWCatalogEntry) -> Void) {
            self.onSelect = onSelect
        }
    }
    /// 编辑 cpu/memory 弹窗的当前 VM. 非 nil → DialogOverlay 显示 EditConfigDialog 模态
    public var editConfigItem: VMListItem? = nil
    /// 新建 snapshot 弹窗的当前 VM. 非 nil → DialogOverlay 显示 SnapshotCreateDialog 模态
    public var snapshotCreateItem: VMListItem? = nil
    /// 新建数据盘弹窗的当前 VM. 非 nil → DialogOverlay 显示 DiskAddDialog 模态
    public var diskAddItem: VMListItem? = nil
    /// 扩容磁盘弹窗的请求 (item + diskID + 当前大小). 非 nil → DialogOverlay 显示 DiskResizeDialog 模态
    public var diskResizeRequest: DiskResizeRequest? = nil

    /// 扩容请求载体: VM 引用 + 磁盘 id (主盘 "main" / 数据盘 uuid8) + 当前 GiB
    public struct DiskResizeRequest: Identifiable, Sendable {
        public let id: UUID
        public let item: VMListItem
        public let diskID: String
        public let currentSizeGiB: UInt64
        public init(item: VMListItem, diskID: String, currentSizeGiB: UInt64) {
            self.id = UUID()
            self.item = item
            self.diskID = diskID
            self.currentSizeGiB = currentSizeGiB
        }
    }

    public struct InstallProgressState: Sendable, Equatable {
        public let id: UUID
        public let displayName: String
        public var phase: Phase
        public var fraction: Double

        public enum Phase: String, Sendable, Equatable {
            case preparing, installing, finalizing
        }
    }

    /// virtio-win.iso 下载进度 (Win11 装机驱动). 由 startVirtioWinFetch 维护.
    public struct VirtioWinFetchState: Sendable, Equatable {
        public var receivedBytes: Int64
        public var totalBytes: Int64?     // 服务端 Content-Length, 缺失时 UI 退化为字节数

        public var fraction: Double? {
            guard let t = totalBytes, t > 0 else { return nil }
            return Double(receivedBytes) / Double(t)
        }
    }

    /// IPSW 下载进度. 由 startIpswFetch 维护, IpswFetchBanner 读.
    public struct IpswFetchState: Sendable, Equatable {
        public var phase: Phase
        /// 例 "macOS 15.0.1 (24A335)"; resolving 阶段为 "querying Apple…"
        public var info: String
        public var receivedBytes: Int64
        public var totalBytes: Int64?
        /// 下载速率 (bytes/sec). nil = 起步阶段还没足够样本
        public var bytesPerSecond: Double?
        /// 预计剩余秒数. nil = 速率或 totalBytes 未知
        public var etaSeconds: Double?

        public enum Phase: String, Sendable, Equatable {
            case resolving, downloading, alreadyCached, completed
        }
    }

    /// vmnet daemon 状态 (statusBar chip + popover 用). 启动后自动 2s 轮询.
    public let vmnet = VmnetStatusModel()

    /// 1Hz tick refreshList: 兜底捕获所有 VM 状态切换 (host 子进程退出 / hvm-cli 起停 /
    /// QEMU 装机后 reboot 自退). refreshList 内部 mtime 缓存保证只在 BundleLock 状态变化
    /// 时实际更新 list, 1Hz 探测开销可接受.
    private var stateTickTimer: Timer?

    public init() {
        vmnet.startPolling()
        // AppModel 是 App 全生命周期单例, 不需要 deinit 清 timer (进程退出即销毁).
        stateTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshList() }
        }
    }

    // MARK: - 列表管理

    /// 增量刷新列表. mtime 没变就复用缓存项 (省 BundleIO.load), 但 runState (busy 探测)
    /// 始终重读 — flock 状态独立于 config.json mtime, 必须每次实测.
    public func refreshList() {
        let root = HVMPaths.vmsRoot
        let urls = (try? BundleDiscovery.list(in: root)) ?? []
        var items: [VMListItem] = []
        var newCache: [String: (mtime: Date, item: VMListItem)] = [:]

        for u in urls {
            let configURL = BundleLayout.configURL(u)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date) ?? Date.distantPast
            let busy = BundleLock.isBusy(bundleURL: u)
            let runState = busy ? "running" : "stopped"

            // 命中: mtime 一致 → 复用 config + bundleURL, 仅刷新 runState
            if let cached = refreshCache[u.path], cached.mtime == mtime {
                var item = cached.item
                item.runState = runState
                items.append(item)
                newCache[u.path] = (mtime, item)
                continue
            }

            // 未命中: load config 重建
            guard let cfg = try? BundleIO.load(from: u) else { continue }
            let item = VMListItem(bundleURL: u, config: cfg, runState: runState)
            items.append(item)
            newCache[u.path] = (mtime, item)
        }

        self.refreshCache = newCache
        self.list = items.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

        // 选中项若已不存在, 清选
        if let sel = selectedID, !list.contains(where: { $0.id == sel }) {
            selectedID = list.first?.id
        } else if selectedID == nil {
            selectedID = list.first?.id
        }

        // QEMU host 子进程退出 (BundleLock 释放, runState→stopped) 后, fanout 上的
        // channel 已断, detached 窗口若还开着会显示僵尸画面 — 主动拆掉.
        // 此处依赖 isBusy() 周期性探测 (refreshList 由 sidebar / popover / timer 触发).
        let staleFanoutIDs = qemuFanouts.keys.filter { id in
            guard let item = list.first(where: { $0.id == id }) else { return true }
            return item.runState != "running"
        }
        for id in staleFanoutIDs { tearDownQemuFanout(id: id) }

        // QEMU 后端 VM 已 running 但还没 fanout (典型: hvm-cli start 拉起 VM 后用户首次
        // open HVM.app, 此时若不 click 任何 VM, fanout 不会 lazy 启 → .gui.sock 不存在 →
        // hvm-dbg display-resize 等自动化测试无法连入). 这里 refresh 时主动 ensure
        // fanout, 让 GUI 一打开就可被 IPC 驱动. 没 view 订阅时 fanout 仍正常拉 surface 事件,
        // channel.requestResize / vdagent.sendMonitorsConfig 调通 (因为它们不依赖 view).
        for item in list where item.runState == "running" && item.config.engine == .qemu {
            if qemuFanouts[item.id] == nil {
                _ = ensureQemuFanout(id: item.id, bundleURL: item.bundleURL)
            }
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
        // QEMU 后端: 派生 HVM 自身二进制走 --host-mode-bundle 入 QemuHostEntry; QEMU 自带 cocoa 窗口,
        // GUI 主窗口不嵌入 (与 VZ 路径区分). stop / kill 走 IPC fallback (见 stop/kill 方法).
        if item.config.engine == .qemu {
            // 与子进程 argv 使用同一套路径, 避免 symlink / 简写 导致 .lock 与 isBusy 判在不同 inode 上
            let bundleURL = item.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            try spawnExternalHost(bundleURL: bundleURL, config: item.config)
            // 轮询子进程是否成功拿到 BundleLock (子进程在 HVMHostEntry 入口即抢锁; 冷启动 dyld/首次签名偶发 >5s)
            // 与 QMP 超时同一量级, 留足 bridged + socket_vmnet 起 sidecar 前的余量 (HVMTimeout.hostStartupLockPoll)
            let waitSeconds = HVMTimeout.hostStartupLockPoll
            let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
            var locked = false
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if BundleLock.isBusy(bundleURL: bundleURL) { locked = true; break }
            }
            refreshList()
            if !locked {
                let logDir = HVMPaths.vmLogsDir(displayName: item.config.displayName, id: item.config.id).path
                throw HVMError.backend(.qemuHostStartupTimeout(waitedSeconds: waitSeconds, logPath: logDir))
            }
            return
        }
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

    /// QEMU 后端 (外部进程) 启动. 派生 self binary 走 --host-mode-bundle,
    /// 子进程进 main.swift if 分支 → HVMHostEntry.run → QemuHostEntry.run.
    /// stdout/stderr 落全局 ~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/host-<date>.log
    /// (与 hvm-cli StartCommand 一致).
    private func spawnExternalHost(bundleURL: URL, config: VMConfig) throws {
        guard let exec = Bundle.main.executableURL else {
            throw HVMError.backend(.vzInternal(description: "无法定位 HVM.app 二进制"))
        }
        let logURL = try makeHostLogURL(displayName: config.displayName, id: config.id)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let proc = Process()
        proc.executableURL = exec
        // --gui-embedded: 告诉 host 子进程它是被 GUI 主进程派生的, 跳过自己装
        // menu bar status item (GUI 主进程已有, 避免重复图标).
        proc.arguments = ["--host-mode-bundle", bundleURL.path, "--gui-embedded"]
        proc.standardOutput = handle
        proc.standardError = handle
        try proc.run()
    }

    /// host-<date>.log 路径准备. 与 HostLauncher.makeHostLogURL 等价 (二者属不同模块,
     /// 各自实现避免 UI ↔ hvm-cli 互相依赖).
    private func makeHostLogURL(displayName: String, id: UUID) throws -> URL {
        let dir = HVMPaths.vmLogsDir(displayName: displayName, id: id)
        try HVMPaths.ensure(dir)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("host-\(df.string(from: Date())).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    public func stop(_ id: UUID) throws {
        if let s = sessions[id] {
            try s.requestStop()
            return
        }
        // 外部进程 (QEMU 后端): 走 IPC stop op
        try sendIPC(id: id, op: .stop)
    }

    public func pause(_ id: UUID) async throws {
        guard let s = sessions[id] else {
            try sendIPC(id: id, op: .pause); return
        }
        try await s.pause()
    }

    public func resume(_ id: UUID) async throws {
        guard let s = sessions[id] else {
            try sendIPC(id: id, op: .resume); return
        }
        try await s.resume()
    }

    public func kill(_ id: UUID) async throws {
        if let s = sessions[id] {
            try await s.forceStop()
        } else {
            try sendIPC(id: id, op: .kill)
        }
        // 不在此处 sessions.removeValue + refreshList:
        // forceStop 走完时, state observer 的 Task { @MainActor in onStateChanged(.stopped) }
        // 还没派发. 若此处 removeValue, 唯一的 local 强引用 s 出 scope 后 VMSession 立即 dealloc,
        // observer 的 [weak self] 失效, cleanup() / onEnded 都不会跑, BundleLock 只能靠
        // BundleLock.deinit 兜底释放 — 而那时 refreshList 已经读过 isBusy=true (同进程 fcntl
        // flock 互斥) 把 runState 写成 running, sidebar 卡死.
        // 让 sessions / list 收尾走 VMSession.onStateChanged -> cleanup -> onEnded -> sessionDidEnd
        // 这条统一路径: cleanup 同步释放 lock, sessionDidEnd 的 refreshList 读到 busy=false.
    }

    /// 给外部 host 进程 (QEMU 后端) 发 IPC 控制命令. 内部走 BundleLock.inspect 取 socket path.
    /// 返回 ok 状态; 不 ok 则抛 HVMError.ipc.remoteError.
    private func sendIPC(id: UUID, op: IPCOp) throws {
        guard let item = list.first(where: { $0.id == id }) else { return }
        guard let holder = BundleLock.inspect(bundleURL: item.bundleURL),
              !holder.socketPath.isEmpty else {
            throw HVMError.ipc(.socketNotFound(path: "(inspect 失败)"))
        }
        let req = IPCRequest(op: op.rawValue)
        let resp = try SocketClient.request(socketPath: holder.socketPath, request: req)
        guard resp.ok else {
            throw HVMError.ipc(.remoteError(
                code: resp.error?.code ?? "ipc.remote_error",
                message: resp.error?.message ?? "\(op.rawValue) 失败"
            ))
        }
        // refresh: 让 sidebar 状态从 running 切回 stopped (host 进程会在退出时释放 BundleLock)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.refreshList()
        }
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

    // MARK: - IPSW 下载

    /// 异步下载指定 IPSW (entry=nil 时走 resolveLatest 取 Apple 推荐最新) 到 cache,
    /// 完成后回调 onComplete 把本地路径回填上层 (向导).
    /// 失败走 errors.present 标准错误弹窗, 不调 onComplete.
    /// 进度通过 ipswFetchState 更新, IpswFetchDialog 读.
    ///
    /// AppModel 是 App 生命周期内的根对象, 不用 [weak self] (单例语义).
    /// IPSWFetcher 的 onProgress 闭包是 @Sendable (在 URLSession 后台 queue 调), 这里跨 actor 调度回 MainActor.
    public func startIpswFetch(
        entry: IPSWCatalogEntry? = nil,
        errors: ErrorPresenter,
        onComplete: @escaping @MainActor (URL) -> Void
    ) {
        let initialInfo = entry.map { "macOS \($0.osVersion) (\($0.buildVersion))" } ?? "querying Apple…"
        ipswFetchState = IpswFetchState(
            phase: .resolving,
            info: initialInfo,
            receivedBytes: 0,
            totalBytes: nil,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        Task { @MainActor in
            do {
                let resolved: IPSWCatalogEntry = try await {
                    if let entry { return entry }
                    return try await IPSWFetcher.resolveLatest()
                }()
                self.ipswFetchState = IpswFetchState(
                    phase: .downloading,
                    info: "macOS \(resolved.osVersion) (\(resolved.buildVersion))",
                    receivedBytes: 0,
                    totalBytes: nil,
                    bytesPerSecond: nil,
                    etaSeconds: nil
                )
                let local = try await IPSWFetcher.downloadIfNeeded(entry: resolved) { p in
                    Task { @MainActor [self] in
                        self.applyIpswProgress(p)
                    }
                }
                self.ipswFetchState = nil
                onComplete(local)
            } catch {
                self.ipswFetchState = nil
                errors.present(error)
            }
        }
    }

    /// 把 IPSWFetchProgress 应用到 ipswFetchState. 在 MainActor 上调.
    private func applyIpswProgress(_ p: IPSWFetchProgress) {
        guard var s = ipswFetchState else { return }
        switch p.phase {
        case .resolving:
            s.phase = .resolving
        case .alreadyCached:
            s.phase = .alreadyCached
        case .downloading:
            s.phase = .downloading
        case .completed:
            s.phase = .completed
        }
        s.receivedBytes = p.receivedBytes
        s.totalBytes = p.totalBytes
        s.bytesPerSecond = p.bytesPerSecond
        s.etaSeconds = p.etaSeconds
        ipswFetchState = s
    }

    // MARK: - virtio-win 下载

    /// 异步确保 virtio-win.iso 已缓存. 已就绪即立即 onComplete; 否则前台下载 + 进度上报.
    /// 失败走 errors.present, 不调 onComplete.
    /// 与 startIpswFetch 同模式: 进度通过 virtioWinFetchState 更新, VirtioWinFetchDialog 读.
    public func startVirtioWinFetch(
        errors: ErrorPresenter,
        onComplete: @escaping @MainActor () -> Void
    ) {
        if VirtioWinCache.isReady {
            // 已缓存: 直接 onComplete, 不弹 dialog
            onComplete()
            return
        }
        virtioWinFetchState = VirtioWinFetchState(receivedBytes: 0, totalBytes: nil)
        Task { @MainActor in
            do {
                _ = try await VirtioWinCache.ensureCached { p in
                    Task { @MainActor [self] in
                        self.virtioWinFetchState = VirtioWinFetchState(
                            receivedBytes: p.receivedBytes,
                            totalBytes: p.totalBytes
                        )
                    }
                }
                self.virtioWinFetchState = nil
                onComplete()
            } catch {
                self.virtioWinFetchState = nil
                errors.present(error)
            }
        }
    }

    /// session 自然结束时通知 (guestDidStop / error) -> 从 sessions 移除
    public func sessionDidEnd(_ id: UUID) {
        sessions.removeValue(forKey: id)
        if embeddedID == id { embeddedID = nil }
        refreshList()
    }

    // MARK: - 嵌入 (M2 VZ 通路唯一显示模式; QEMU 通路走 qemuFanouts)

    public func embedInMain(_ id: UUID) {
        guard let s = sessions[id] else { return }
        s.showEmbedded()
        embeddedID = id
    }

    // MARK: - QEMU fanout / detached 窗口

    /// 确保该 VM 有一个活跃的 fanout session. 不存在则创建 + start; 已存在则原样复用.
    /// 调用方负责 addSubscriber + (subscribers 全空时) tearDownQemuFanoutIfIdle.
    /// internal: QemuFanoutSession 类型 internal, API 跟着 internal.
    func ensureQemuFanout(id: UUID, bundleURL: URL) -> QemuFanoutSession {
        if let existing = qemuFanouts[id] { return existing }
        let fanout = QemuFanoutSession(vmID: id, bundleURL: bundleURL)
        qemuFanouts[id] = fanout
        // 监听 QEMU host 进程退出 (Win 装机后 reboot / kill / panic 均会触发 channel
        // 断开). 否则 GUI 停在 "running 黑屏", 必须等下次 refreshList 兜底才切.
        fanout.onDisconnected = { [weak self, id] in
            self?.handleQemuFanoutDisconnected(id: id)
        }
        fanout.start()
        startQemuGUIControlServer(id: id)
        return fanout
    }

    /// 启 GUI 端 control IPC server (hvm-dbg display-resize 用). per-VM, 跟 fanout
    /// 同生命周期. handler 在 IPC 线程被调用 (nonisolated), dispatch 回 MainActor
    /// 触发 fanout.fireResize, 然后用 DispatchSemaphore 把结果同步回 IPC 线程
    /// (SocketServer.Handler 是 sync 接口).
    private func startQemuGUIControlServer(id: UUID) {
        guard qemuGUIServers[id] == nil else { return }
        let socketURL = HVMPaths.guiControlSocketPath(for: id)
        let server = SocketServer(socketPath: socketURL)
        // weakSelf: 允许 AppModel 在 GUI 退出时被释放 — handler 闭包不长留 main 引用
        let weakBox = WeakAppModelBox(self)
        let handler: SocketServer.Handler = { @Sendable req in
            return Self.dispatchGUIControl(weakBox: weakBox, vmID: id, req: req)
        }
        do {
            try server.start(handler: handler)
            qemuGUIServers[id] = server
        } catch {
            // 失败不阻塞主路径 — 只是 hvm-dbg display-resize 用不了 (等同 GUI 关闭).
            HVMLog.logger("ipc.gui").error("GUI control server start failed for vm=\(id.uuidString): \(String(describing: error))")
        }
    }

    /// nonisolated 入口 — 在 SocketServer accept 线程被调. 解析 op, 跳到 MainActor
    /// 调 fanout.fireResize, 同步等结果. 单连接单请求/响应模式, semaphore 不会死锁.
    nonisolated private static func dispatchGUIControl(
        weakBox: WeakAppModelBox, vmID: UUID, req: IPCRequest
    ) -> IPCResponse {
        switch req.op {
        case IPCOp.dbgDisplayResize.rawValue:
            guard let widthStr = req.args["width"], let heightStr = req.args["height"],
                  let width = UInt32(widthStr), let height = UInt32(heightStr),
                  width > 0, height > 0 else {
                return .failure(id: req.id, code: "ipc.bad_args",
                                message: "dbg.display.resize 需要 width / height 正整数")
            }
            let sem = DispatchSemaphore(value: 0)
            // result 在 MainActor 内写, accept 线程读 — DispatchSemaphore 提供 happens-before
            nonisolated(unsafe) var result: IPCResponse = .failure(
                id: req.id, code: "gui.fanout_unavailable",
                message: "GUI 内 fanout 已释放 (VM 停止 / GUI 关闭中)"
            )
            DispatchQueue.main.async {
                if let model = weakBox.value, let fanout = model.qemuFanouts[vmID] {
                    fanout.fireResize(width: width, height: height)
                    result = .success(id: req.id, data: ["width": "\(width)", "height": "\(height)"])
                }
                sem.signal()
            }
            sem.wait()
            return result
        default:
            return .failure(id: req.id, code: "ipc.unknown_op",
                            message: "GUI control 不认 op: \(req.op)")
        }
    }

    /// fanout channel 断开 (host 子进程退出 / 远端 GOODBYE / IO 错误) 时调.
    /// 拆 fanout + 关闭 detached 窗口 + 立即 refreshList; 再延迟 500ms 兜底一次,
    /// 因为 host 进程 fork 退出 → BundleLock 真正 unlock 之间有微秒级 kernel cleanup
    /// 延迟, 第一次 refreshList 偶发仍读到 isBusy=true (跟 sendIPC 末尾同模式).
    private func handleQemuFanoutDisconnected(id: UUID) {
        tearDownQemuFanout(id: id)
        refreshList()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.refreshList()
        }
    }

    /// VM 停止 / host 子进程退出后, 强制拆掉 fanout + 关闭可能存在的 detached 窗口.
    /// channel 已断时, view 上仍能显示最后一帧 (renderer 持 mmap), 关 detached 窗口
    /// 释放该 view 的 mmap 引用; 主窗口的 fanout view 由 DetailContainerView transition
    /// (.runningRemote → .stopped) 时自动清.
    public func tearDownQemuFanout(id: UUID) {
        if let fanout = qemuFanouts.removeValue(forKey: id) {
            fanout.stop()
        }
        if let server = qemuGUIServers.removeValue(forKey: id) {
            server.stop()
        }
        closeDetachedQemuWindow(id: id)
    }

    /// 当 subscriber 计数归零时调用; 若该 VM 仍 running 则什么都不做 (后续可能再开),
    /// 实际上会在 VM 停止时由 tearDownQemuFanout 强制清理. 这里保留 hook 给将来想做
    /// "无人查看 → 节省 QMP/socket 资源"的优化, 当前实现是 no-op (保证嵌入和独立窗口
    /// 之间快速切换不重连 channel, 体验更顺).
    public func tearDownQemuFanoutIfIdle(id: UUID) {
        guard let fanout = qemuFanouts[id] else { return }
        if fanout.activeSubscriberCount == 0 {
            // 当前策略: 保留, 不立即拆. VM 停止时由 tearDownQemuFanout 兜底.
            _ = fanout
        }
    }

    /// 弹出独立窗口 (共存式: 主窗口嵌入仍可同时存在).
    /// 已弹出再调一次会把窗口前置 (orderFrontRegardless), 不重复创建.
    public func openDetachedQemu(id: UUID, item: VMListItem) {
        if let existing = detachedQemuWindowControllers[id] {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.window?.orderFrontRegardless()
            return
        }
        let fanout = ensureQemuFanout(id: id, bundleURL: item.bundleURL)
        let controller = DetachedVMWindowController(model: self, item: item, fanout: fanout)
        detachedQemuWindowControllers[id] = controller
        detachedQemuVMs.insert(id)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 关闭独立窗口. 由 detach 按钮再点一次 / 窗口 X 按钮 / VM 停止触发.
    public func closeDetachedQemuWindow(id: UUID) {
        if let controller = detachedQemuWindowControllers.removeValue(forKey: id) {
            controller.tearDown()
        }
        detachedQemuVMs.remove(id)
    }

    /// detach 按钮 toggle: 已开就关, 没开就开.
    public func toggleDetachedQemu(id: UUID) {
        if detachedQemuWindowControllers[id] != nil {
            closeDetachedQemuWindow(id: id)
        } else if let item = list.first(where: { $0.id == id }) {
            openDetachedQemu(id: id, item: item)
        }
    }
}

/// AppModel 是 @MainActor 类, 不能直接被 SocketServer 的 @Sendable handler 闭包
/// 通过 weak 引用. 包一层裸 weak class 容器, 让闭包持 nonisolated WeakBox 即可.
/// 读 .value 必须在 MainActor (因为 AppModel 是 MainActor-isolated).
private final class WeakAppModelBox: @unchecked Sendable {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}
