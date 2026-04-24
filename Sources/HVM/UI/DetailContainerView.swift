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
import HVMDisplay

@MainActor
final class DetailContainerView: NSView {
    private let model: AppModel
    private let errors: ErrorPresenter

    // 当前展示的 hosting view, 根据状态重建
    private var currentEmptyHost: NSHostingView<DetailEmptyState>?
    private var currentStoppedHost: NSHostingView<StoppedContentView>?
    private var currentTopBar: NSHostingView<DetailTopBar>?
    private var currentBottomBar: NSHostingView<DetailBottomBar>?

    // 当前挂载的 HVMView (引用 session.attachment.view, 不 retain)
    private weak var currentHVMView: HVMView?

    // 追踪当前 AppModel 状态对应的 VM id, 用于决定是否需要重建/切换
    private var shownID: UUID?
    private var shownState: ShowState = .empty

    private enum ShowState: Equatable {
        case empty
        case stopped(UUID)
        case running(UUID)
    }

    init(model: AppModel, errors: ErrorPresenter) {
        self.model = model
        self.errors = errors
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        subscribeModel()
        refresh()
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
                // 同时订阅当前 session.state (若 running)
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
        if newState != shownState {
            transition(to: newState)
            shownState = newState
        }
    }

    private func computeState() -> ShowState {
        guard let sel = model.selectedID else { return .empty }
        guard model.list.contains(where: { $0.id == sel }) else { return .empty }
        if model.sessions[sel] != nil {
            return .running(sel)
        }
        return .stopped(sel)
    }

    private func transition(to state: ShowState) {
        // 清掉旧
        currentEmptyHost?.removeFromSuperview(); currentEmptyHost = nil
        currentStoppedHost?.removeFromSuperview(); currentStoppedHost = nil
        currentTopBar?.removeFromSuperview(); currentTopBar = nil
        currentBottomBar?.removeFromSuperview(); currentBottomBar = nil
        currentHVMView?.removeFromSuperview(); currentHVMView = nil

        switch state {
        case .empty:
            buildEmpty()
        case .stopped(let id):
            buildStopped(id: id)
        case .running(let id):
            buildRunning(id: id)
        }
    }

    // MARK: - 各态构造

    private func buildEmpty() {
        let host = NSHostingView(rootView: DetailEmptyState())
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        currentEmptyHost = host
    }

    private func buildStopped(id: UUID) {
        guard let item = model.list.first(where: { $0.id == id }) else { buildEmpty(); return }
        let host = NSHostingView(rootView: StoppedContentView(model: model, errors: errors, item: item))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .minSize
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
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
            topBar.topAnchor.constraint(equalTo: topAnchor),
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

    private func makeHorizontalDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }
}
