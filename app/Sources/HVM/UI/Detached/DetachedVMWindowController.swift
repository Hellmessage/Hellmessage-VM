// DetachedVMWindowController.swift
//
// QEMU 后端 VM 的"独立窗体"窗口. 跟主窗口的嵌入路径**共存**:
//   - 同一 fanout session, 同一 VM 同一份 IOSurface
//   - 主窗口右栏的 FramebufferHostView 仍持续渲染 (resize master)
//   - 独立窗口里的 FramebufferHostView 是另一个 fanout subscriber, 跟主窗口
//     同步显示但不发 resize 请求 (避免两边拉锯改 guest 分辨率)
//   - 输入: 各 view 自带 InputForwarder, key window 那个 view 拿到 NSEvent,
//     自动只有一边发输入到 guest
//
// 标题栏: 标准 NSWindow titlebar (红绿黄按钮 + 标题=VM displayName).
// 关闭按钮: 等价于 AppModel.closeDetachedQemuWindow, 不会停 VM, 仅收回独立显示.

import AppKit
import SwiftUI
import HVMDisplayQemu

@MainActor
final class DetachedVMWindowController: NSWindowController, NSWindowDelegate {

    private let model: AppModel
    private let vmID: UUID
    private let fanout: QemuFanoutSession
    /// 这个独立窗口里的 framebuffer view. fanout subscriber, 不当 resize master.
    private var fbView: FramebufferHostView?
    private var topBarHost: NSHostingView<DetailTopBar>?
    private var bottomBarHost: NSHostingView<DetailBottomBar>?
    private var observationTask: Task<Void, Never>?

    /// 默认窗口尺寸 / 最小尺寸. 独立窗口主要用来在副屏全屏看 guest, 给个 1024x768
    /// 起步, 用户可拖大或全屏切.
    private static let defaultSize = NSSize(width: 1024, height: 768)
    private static let minSize     = NSSize(width: 640,  height: 480)

    init(model: AppModel, item: AppModel.VMListItem, fanout: QemuFanoutSession) {
        self.model = model
        self.vmID = item.id
        self.fanout = fanout

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = item.displayName
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        // 黑底, 跟嵌入路径视觉一致 (CLAUDE.md: 主窗口不跟随系统主题, 走深色)
        window.backgroundColor = NSColor.black
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        super.init(window: window)
        window.delegate = self
        installContentView(item: item)
        observeItemUpdates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observationTask?.cancel()
    }

    /// AppModel.closeDetachedQemuWindow 调用; 触发后窗口先 unsubscribe + close.
    /// windowWillClose delegate 不再回调 AppModel (避免双重 closeDetached).
    func tearDown() {
        observationTask?.cancel(); observationTask = nil
        if let v = fbView {
            fanout.removeSubscriber(v)
            v.removeFromSuperview()
        }
        fbView = nil
        topBarHost = nil
        bottomBarHost = nil
        // 切断 delegate 防止 close → windowWillClose → AppModel 二次 closeDetached
        window?.delegate = nil
        window?.close()
    }

    // MARK: - 内容布局 (复用 DetailContainerView 的 TopBar / Framebuffer / BottomBar 三段)

    private func installContentView(item: AppModel.VMListItem) {
        guard let window = self.window else { return }
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSHostingView(rootView: DetailTopBar(model: model, item: item))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.sizingOptions = .intrinsicContentSize
        topBar.setContentHuggingPriority(.required, for: .vertical)
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)
        self.topBarHost = topBar

        // sharedErrors 在 HVMAppDelegate 启动时注入; 兜底用一个 detached 自己的
        // ErrorPresenter (报错只会写自己的 queue, DialogOverlay 看不到 — 但保证不崩).
        let errors = model.sharedErrors ?? ErrorPresenter()
        let bottomBar = NSHostingView(rootView: DetailBottomBar(
            model: model,
            errors: errors,
            item: item
        ))
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.sizingOptions = .intrinsicContentSize
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        bottomBar.setContentCompressionResistancePriority(.required, for: .vertical)
        self.bottomBarHost = bottomBar

        let fb = FramebufferHostView(frame: .zero)
        fb.translatesAutoresizingMaskIntoConstraints = false
        fb.setContentHuggingPriority(.defaultLow, for: .vertical)
        fb.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        self.fbView = fb

        let topDivider = makeDivider()
        let bottomDivider = makeDivider()

        root.addSubview(topBar)
        root.addSubview(topDivider)
        root.addSubview(fb)
        root.addSubview(bottomDivider)
        root.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            fb.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            fb.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            fb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fb.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bottomDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        window.contentView = root

        // 注册成 fanout subscriber (非 resize master), fanout 会立即 replay 当前 surface
        fanout.addSubscriber(fb, isResizeMaster: false)
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }

    // MARK: - 监听 item 变化 (displayName 改 → 窗口 title 跟着改)

    private func observeItemUpdates() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            // 简化: 1Hz 轮询 list 里的 displayName 变化即可, 改名是低频操作
            while let self, !Task.isCancelled {
                if let item = self.model.list.first(where: { $0.id == self.vmID }),
                   self.window?.title != item.displayName {
                    self.window?.title = item.displayName
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 用户点 X / cmd+W 关窗 → 通知 AppModel 清状态. AppModel 会回调 tearDown,
        // 但 tearDown 里已切断 delegate, 此回调不会再次进入.
        model.closeDetachedQemuWindow(id: vmID)
    }
}
