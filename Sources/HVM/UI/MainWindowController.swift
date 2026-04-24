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

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let errors: ErrorPresenter

    init(model: AppModel, errors: ErrorPresenter) {
        self.model = model
        self.errors = errors

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
        // 方便 bash 脚本做集成测试, 不用手点 GUI.
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

        // Dialog overlay 最顶层
        let overlay = NSHostingView(rootView: DialogOverlay(model: model, errors: errors))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = .minSize

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
