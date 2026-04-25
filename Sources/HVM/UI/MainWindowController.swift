// MainWindowController.swift
// AppKit 外壳. 整体布局:
//
//  ┌─────────────── toolbar (SwiftUI via NSHostingView) ───────────────┐
//  ├──────────────┬─────────────────────────────────────────────────────┤
//  │  sidebar     │                                                     │
//  │  (SwiftUI)   │   DetailContainerView (AppKit)                      │
//  │              │      stopped: NSHostingView<StoppedContentView>    │
//  │              │      running: HVMView (直挂 AppKit) + top/bottom   │
//  │              │                                                     │
//  ├──────────────┴─────────────────────────────────────────────────────┤
//  │                   status bar (SwiftUI via NSHostingView)           │
//  └────────────────────────────────────────────────────────────────────┘
//  + dialog overlay (SwiftUI 最顶层, 透明点击穿透)
//
// X 按钮不真的关闭 app, 而是 hide window + 切到 menu bar accessory 模式
// (Dock 图标隐藏, 顶部状态栏出现一个图标). 实现见 HVMAppDelegate.

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let errors: ErrorPresenter
    private let confirms: ConfirmPresenter

    /// 用户点 window 关闭按钮时被调. 由 AppDelegate 注入回调切到 menu bar 模式.
    var onCloseRequested: (() -> Void)?

    init(model: AppModel, errors: ErrorPresenter, confirms: ConfirmPresenter) {
        self.model = model
        self.errors = errors
        self.confirms = confirms

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HVM"
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1020, height: 640)
        window.center()

        super.init(window: window)
        window.delegate = self
        setupLayout()

        // 首次刷新列表
        model.refreshList()

        // 测试 hook: HVM_AUTOSTART_VM=<name> 启动后自动 start 对应 VM.
        if let name = ProcessInfo.processInfo.environment["HVM_AUTOSTART_VM"],
           let item = model.list.first(where: { $0.displayName == name }) {
            model.selectedID = item.id
            Task {
                do { try await model.start(item) }
                catch { errors.present(error) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 不真正 close, 仅 orderOut (隐藏). AppDelegate 切到 accessory 模式.
        sender.orderOut(nil)
        onCloseRequested?()
        return false
    }

    // MARK: - 布局

    private func setupLayout() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        // 关键: 强制初始 content size, 避免 NSHostingView intrinsic size 把 window 挤小
        window?.setContentSize(NSSize(width: 1080, height: 720))

        // SwiftUI 子视图
        let toolbar = NSHostingView(rootView: HVMToolbar(model: model, errors: errors))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.sizingOptions = .minSize

        let sidebar = NSHostingView(rootView: SidebarView(model: model, errors: errors))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.sizingOptions = .minSize

        let statusBar = NSHostingView(rootView: HVMStatusBar(model: model))
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.sizingOptions = .minSize

        // 细边分隔
        let topDivider = makeHDivider()
        let bottomDivider = makeHDivider()
        let vDivider = makeVDivider()

        // AppKit detail 容器
        let detail = DetailContainerView(model: model, errors: errors)

        // Dialog overlay 最顶层. 必须用 PassthroughHostingView, 否则透明区域吞所有点击
        let overlay = PassthroughHostingView(rootView: DialogOverlay(model: model, errors: errors, confirms: confirms))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = .minSize
        // 实时检测, 避开 withObservationTracking 异步 onChange 的 timing race
        overlay.isAnyDialogActive = { [weak model, weak errors, weak confirms] in
            (model?.showCreateWizard ?? false)
                || (model?.installState != nil)
                || (model?.editConfigItem != nil)
                || (errors?.current != nil)
                || (confirms?.current != nil)
        }
        observeDialogActivity(overlay: overlay)

        contentView.addSubview(toolbar)
        contentView.addSubview(topDivider)
        contentView.addSubview(sidebar)
        contentView.addSubview(vDivider)
        contentView.addSubview(detail)
        contentView.addSubview(bottomDivider)
        contentView.addSubview(statusBar)
        contentView.addSubview(overlay)

        NSLayoutConstraint.activate([
            // Toolbar 顶部全宽
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: HVMBar.toolbarHeight),

            topDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            // StatusBar 底部全宽
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: HVMBar.statusBarHeight),

            bottomDivider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomDivider.heightAnchor.constraint(equalToConstant: 1),

            // Sidebar 左侧 240pt
            sidebar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),

            // 垂直分隔线
            vDivider.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            vDivider.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            vDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            vDivider.widthAnchor.constraint(equalToConstant: 1),

            // Detail 右侧
            detail.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor),
            detail.leadingAnchor.constraint(equalTo: vDivider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Overlay 全覆盖
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    /// 观察"是否有弹窗在前", 同步给 overlay (cursor rect) + 所有运行中 VMSession 的 HVMView.
    /// VZVirtualMachineView 用全局 NSCursor.hide() 隐藏光标 (不是 cursor rect), AppKit 层覆盖
    /// 的 cursor rect 压不过, 所以必须在 HVMView 自己里 inputSuspended 屏蔽 VZ 的 mouse* 处理.
    private func observeDialogActivity(overlay: PassthroughHostingView<DialogOverlay>) {
        withObservationTracking {
            let active = model.showCreateWizard
                || model.installState != nil
                || model.editConfigItem != nil
                || errors.current != nil
                || confirms.current != nil
            overlay.dialogActive = active
            for session in model.sessions.values {
                session.attachment.view.inputSuspended = active
            }
        } onChange: { [weak self, weak overlay] in
            Task { @MainActor in
                guard let self, let overlay else { return }
                self.observeDialogActivity(overlay: overlay)
            }
        }
    }

    private func makeHDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }

    private func makeVDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }
}
