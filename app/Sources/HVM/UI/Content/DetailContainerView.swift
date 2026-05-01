// DetailContainerView.swift
// AppKit 侧的"右栏详情区"容器. 职责:
//   - 无选中 VM → 显示空状态 (NSHostingView<DetailEmptyState>)
//   - 选中 stopped VM → 显示 StoppedContentView (NSHostingView)
//   - 选中 running VM → 垂直布局:
//         顶栏 (NSHostingView<DetailTopBar>)
//         中间 HVMView (纯 AppKit, VZ 画面区)
//         底栏 (NSHostingView<DetailBottomBar>)
//
// 关键: HVMView 作为本容器的直接 subview, superview 稳定, 不经 SwiftUI NSViewRepresentable,
// 因此 Metal drawable 不会被 SwiftUI 的 layout 流程打断.

import AppKit
import SwiftUI
import Observation
import HVMBundle
import HVMDisplay
import HVMDisplayQemu

@MainActor
final class DetailContainerView: NSView {
    private let model: AppModel
    private let errors: ErrorPresenter
    private let confirms: ConfirmPresenter

    // 当前展示的 hosting view, 根据状态重建
    private var currentEmptyHost: NSHostingView<DetailEmptyState>?
    private var currentStoppedHost: NSHostingView<StoppedContentView>?
    private var currentRemoteRunningHost: NSHostingView<RemoteRunningContentView>?
    private var currentTopBar: NSHostingView<DetailTopBar>?
    private var currentBottomBar: NSHostingView<DetailBottomBar>?

    // 当前挂载的 HVMView (引用 session.attachment.view, 不 retain)
    private weak var currentHVMView: HVMView?

    // QEMU 嵌入路径当前 view + 它订阅的 fanout (fanout 由 AppModel 持有,
    // 主窗口嵌入 + detached 独立窗口可同时各持一个 view 订阅同一 fanout).
    // transition 离开 qemu running 状态时, removeSubscriber + view.removeFromSuperview.
    private weak var currentQemuFanoutView: FramebufferHostView?
    private var currentQemuFanoutVMID: UUID?

    // 顶部"运行中 VM" tab 栏, 跟 sub-state UI 解耦, 一直存在;
    // 高度由 runningTabsBarHeight 约束动态控制 (0 个运行中 VM → 0 高度).
    private var runningTabsBar: NSHostingView<RunningTabsBar>!
    private var runningTabsBarHeight: NSLayoutConstraint!
    private static let runningTabsBarMaxHeight: CGFloat = 38

    // 追踪当前 AppModel 状态对应的 VM id, 用于决定是否需要重建/切换
    private var shownID: UUID?
    private var shownState: ShowState = .empty
    /// stopped 视图当前渲染的 config 快照. config 变化 (cpu/memory/iso/disk/...) 时强制 rebuild,
    /// 否则 stopped view 持有的是 init 时 captured 的 immutable item, SwiftUI 不会自动响应外部改动.
    private var shownStoppedConfig: VMConfig?

    private enum ShowState: Equatable {
        case empty
        case stopped(UUID)
        /// 本进程内有 session 的 running (VZ embedded display 路径)
        case running(UUID)
        /// runState=running 但本进程内无 session (QEMU 后端 / hvm-cli 起的 VM):
        /// detail 改用 RemoteRunningContentView 占位, 控制按钮走 model.stop/.kill 的 IPC fallback
        case runningRemote(UUID)
    }

    init(model: AppModel, errors: ErrorPresenter, confirms: ConfirmPresenter) {
        self.model = model
        self.errors = errors
        self.confirms = confirms
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        installRunningTabsBar()
        subscribeModel()
        // 强制构建初始 UI: refresh() 的相等性短路会跳过 shownState 默认值 == 初始 computeState 的情况
        let initial = computeState()
        transition(to: initial)
        shownState = initial
        if case .stopped(let id) = initial,
           let item = model.list.first(where: { $0.id == id }) {
            shownStoppedConfig = item.config
        }
        applyRunningTabsBarVisibility()
        syncEmbeddedInputCapture()
    }

    /// init 时挂一次 tabs bar, 之后不拆建. 高度通过约束动态切.
    private func installRunningTabsBar() {
        let host = NSHostingView(rootView: RunningTabsBar(model: model, errors: errors))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        let h = host.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            h,
        ])
        runningTabsBar = host
        runningTabsBarHeight = h
    }

    /// 根据当前运行中 VM 数量切 tabs bar 显隐.
    private func applyRunningTabsBarVisibility() {
        let runningCount = model.list.filter { $0.runState == "running" }.count
        let target: CGFloat = runningCount > 0 ? Self.runningTabsBarMaxHeight : 0
        if runningTabsBarHeight.constant != target {
            runningTabsBarHeight.constant = target
            runningTabsBar.isHidden = runningCount == 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 订阅 AppModel 变化

    private func subscribeModel() {
        // 使用 Observation framework 的 withObservationTracking 做增量订阅:
        // 每次任一被读属性变化, 重触发 refresh(), refresh 内再次读, 自动建立新依赖
        let tracker = { [weak self] in
            guard let self else { return }
            withObservationTracking {
                // 读取 refresh() 依赖的所有字段以建立依赖
                _ = self.model.selectedID
                _ = self.model.embeddedID
                _ = self.model.list.count
                _ = self.model.sessions.count
                // detachedQemuVMs 变化 → 重 sync 主嵌入 view 的 inputCaptureEnabled
                // (打开独立窗口时主嵌入让出 mouse/key 捕获)
                _ = self.model.detachedQemuVMs
                // 订阅当前选中 VM 的 runState (QEMU 后端无 session, 状态切换只能从 list.runState 看)
                if let sel = self.model.selectedID,
                   let item = self.model.list.first(where: { $0.id == sel }) {
                    _ = item.runState
                }
                // 同时订阅当前 session.state (若 running 且本进程持有 session)
                if let sel = self.model.selectedID, let s = self.model.sessions[sel] {
                    _ = s.state
                }
            } onChange: {
                Task { @MainActor [weak self] in
                    self?.refresh()
                    self?.subscribeModel()  // 重新订阅下一次
                }
            }
        }
        tracker()
    }

    // MARK: - 状态 → UI

    private func refresh() {
        let newState = computeState()
        var needsRebuild = newState != shownState

        // stopped 状态额外检测 config 是否变化 (iso 切换 / cpu/mem 编辑 / boot-from-disk 等
        // 都改 config 不改 ShowState). stopped view 持有的是 init 时的 immutable snapshot,
        // SwiftUI 不会自动响应外部改动 → 必须 host rebuild.
        if !needsRebuild, case .stopped(let id) = newState,
           let curConfig = model.list.first(where: { $0.id == id })?.config,
           curConfig != shownStoppedConfig {
            needsRebuild = true
        }

        if needsRebuild {
            transition(to: newState)
            shownState = newState
            if case .stopped(let id) = newState,
               let item = model.list.first(where: { $0.id == id }) {
                shownStoppedConfig = item.config
            } else {
                shownStoppedConfig = nil
            }
        }
        // tabs bar 显隐独立于 sub-state 重建判定: 任意 VM 启停都要更新.
        applyRunningTabsBarVisibility()
        // 同步嵌入 view 的输入捕获开关 (打开独立窗口时主嵌入让出输入).
        syncEmbeddedInputCapture()
    }

    /// 主窗口的 QEMU 嵌入 view, 当对应 VM 已弹出独立窗口时, 主窗口让出 mouse/key
    /// 捕获 — 让用户操作完全发生在独立窗口里.
    private func syncEmbeddedInputCapture() {
        guard let view = currentQemuFanoutView,
              let id = currentQemuFanoutVMID else { return }
        let detached = model.detachedQemuVMs.contains(id)
        view.inputCaptureEnabled = !detached
    }

    private func computeState() -> ShowState {
        guard let sel = model.selectedID else { return .empty }
        guard let item = model.list.first(where: { $0.id == sel }) else { return .empty }
        // 唯一 source of truth: list.runState (来自 BundleLock 探测), sidebar / statusbar 同源.
        // session 是否存在仅决定 running 走 embedded view (.running) 还是 remote 占位 (.runningRemote).
        if item.runState == "running" {
            if model.sessions[sel] != nil {
                return .running(sel)
            }
            return .runningRemote(sel)
        }
        return .stopped(sel)
    }

    private func transition(to state: ShowState) {
        // 清掉旧
        currentEmptyHost?.removeFromSuperview(); currentEmptyHost = nil
        currentStoppedHost?.removeFromSuperview(); currentStoppedHost = nil
        currentRemoteRunningHost?.removeFromSuperview(); currentRemoteRunningHost = nil
        currentTopBar?.removeFromSuperview(); currentTopBar = nil
        currentBottomBar?.removeFromSuperview(); currentBottomBar = nil
        currentHVMView?.removeFromSuperview(); currentHVMView = nil
        if let view = currentQemuFanoutView, let id = currentQemuFanoutVMID {
            // 从 fanout 注销主窗口嵌入 view; fanout 本身留给 detached 窗口或下次嵌入复用.
            // VM 真停止时由 AppModel.refreshList 末尾的 staleFanoutIDs 清理 + tearDownQemuFanout.
            model.qemuFanouts[id]?.removeSubscriber(view)
            view.removeFromSuperview()
            currentQemuFanoutView = nil
            currentQemuFanoutVMID = nil
            // 如果该 VM 没有 detached 窗口在订阅 + 主窗口刚切走 → fanout 可能空闲,
            // 但当前策略是保留 fanout 直到 VM 停止, 见 tearDownQemuFanoutIfIdle 注释.
            model.tearDownQemuFanoutIfIdle(id: id)
        }

        switch state {
        case .empty:
            buildEmpty()
        case .stopped(let id):
            buildStopped(id: id)
        case .running(let id):
            buildRunning(id: id)
        case .runningRemote(let id):
            buildRemoteRunning(id: id)
        }
    }

    // MARK: - 各态构造

    private func buildEmpty() {
        let host = NSHostingView(rootView: DetailEmptyState(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: runningTabsBar.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        currentEmptyHost = host
    }

    private func buildStopped(id: UUID) {
        guard let item = model.list.first(where: { $0.id == id }) else { buildEmpty(); return }
        let host = NSHostingView(rootView: StoppedContentView(model: model, errors: errors, confirms: confirms, item: item))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: runningTabsBar.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        currentStoppedHost = host
    }

    private func buildRunning(id: UUID) {
        guard let item = model.list.first(where: { $0.id == id }),
              let session = model.sessions[id] else {
            buildEmpty(); return
        }

        let topBar = NSHostingView(rootView: DetailTopBar(model: model, item: item))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.sizingOptions = .intrinsicContentSize
        topBar.setContentHuggingPriority(.required, for: .vertical)
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let bottomBar = NSHostingView(rootView: DetailBottomBar(model: model, errors: errors, item: item))
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.sizingOptions = .intrinsicContentSize
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        bottomBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let topDivider = makeHorizontalDivider()
        let bottomDivider = makeHorizontalDivider()

        let hvmView = session.attachment.view
        hvmView.translatesAutoresizingMaskIntoConstraints = false
        // 让 hvmView 吸收所有剩余空间, topBar/bottomBar 保持 intrinsic
        hvmView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hvmView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(topBar)
        addSubview(topDivider)
        addSubview(hvmView)
        addSubview(bottomDivider)
        addSubview(bottomBar)

        NSLayoutConstraint.activate([
            // TopBar
            topBar.topAnchor.constraint(equalTo: runningTabsBar.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            // HVMView (中间填充)
            hvmView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            hvmView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            hvmView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hvmView.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            // BottomBar
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        currentTopBar = topBar
        currentBottomBar = bottomBar
        currentHVMView = hvmView

        // 让 session 绑定 VM 到 view (view 已在 window hierarchy 就会立即创建 Metal drawable)
        session.bindVMToView()
    }

    /// runState=running 但本进程无 session 时的展示分支:
    ///   - engine == .qemu: 嵌入 FramebufferHostView, 走 HDP socket 拉 framebuffer
    ///     (跟 buildRunning 同布局, 但 view 是 Metal-backed Framebuffer 而非 VZView)
    ///   - 其他 (例如 hvm-cli 起的 VZ VM, 主 GUI 后绑定): RemoteRunningContentView 占位
    private func buildRemoteRunning(id: UUID) {
        guard let item = model.list.first(where: { $0.id == id }) else { buildEmpty(); return }
        if item.config.engine == .qemu {
            buildQemuEmbedded(id: id, item: item)
        } else {
            buildRemoteHosting(id: id, item: item)
        }
    }

    private func buildRemoteHosting(id: UUID, item: AppModel.VMListItem) {
        let host = NSHostingView(rootView: RemoteRunningContentView(model: model, errors: errors, item: item))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: runningTabsBar.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        currentRemoteRunningHost = host
    }

    private func buildQemuEmbedded(id: UUID, item: AppModel.VMListItem) {
        // 拿 (或创建) 该 VM 的 fanout. fanout 是共享资源, detached 窗口也订阅它,
        // 主窗口 transition 离开时只 removeSubscriber, 不停 fanout (除非 VM 真停止).
        let fanout = model.ensureQemuFanout(id: id, bundleURL: item.bundleURL)

        let topBar = NSHostingView(rootView: DetailTopBar(model: model, item: item))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.sizingOptions = .intrinsicContentSize
        topBar.setContentHuggingPriority(.required, for: .vertical)
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let bottomBar = NSHostingView(rootView: DetailBottomBar(model: model, errors: errors, item: item))
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.sizingOptions = .intrinsicContentSize
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        bottomBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let topDivider = makeHorizontalDivider()
        let bottomDivider = makeHorizontalDivider()

        let fbView = FramebufferHostView(frame: .zero)
        fbView.translatesAutoresizingMaskIntoConstraints = false
        fbView.setContentHuggingPriority(.defaultLow, for: .vertical)
        fbView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(topBar)
        addSubview(topDivider)
        addSubview(fbView)
        addSubview(bottomDivider)
        addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: runningTabsBar.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            fbView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            fbView.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            fbView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fbView.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        currentTopBar = topBar
        currentBottomBar = bottomBar
        currentQemuFanoutView = fbView
        currentQemuFanoutVMID = id

        // 主窗口嵌入 view 是 resize master: drawable 尺寸变化 → HDP RESIZE_REQUEST
        // 给 guest 改分辨率. detached 窗口的 view 不当 master, 避免拉锯.
        fanout.addSubscriber(fbView, isResizeMaster: true)
    }

    private func makeHorizontalDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }
}
