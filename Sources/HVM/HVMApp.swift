// HVMApp.swift (M2 AppKit shell + menu bar)
//
// X 关闭按钮不退出 app: hide window + 切到 NSApplication.activationPolicy(.accessory),
// Dock 图标隐藏, 系统右上角状态栏出现 HVM 图标 (NSStatusItem). 点 status item 弹出菜单
// 选 "Show HVM" 重新显示主窗口, 同时切回 .regular activation policy.
//
// 这样用户关闭主窗口后, sessions 里运行中的 VM 仍然在跑 (后台), 通过状态栏图标随时唤回.

import AppKit
import SwiftUI
import HVMBundle
import HVMCore
import HVMNet

@MainActor
final class HVMAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let errors = ErrorPresenter()
    let confirms = ConfirmPresenter()
    private var mainController: MainWindowController?
    private var statusItem: NSStatusItem?
    /// 状态栏弹出的 SwiftUI popover. 点 status item 切换显隐.
    private var statusPopover: NSPopover?
    /// 优雅退出流程进行中, 防止重复触发. true 时 applicationShouldTerminate 直接放行
    private var quittingInProgress = false

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        let wc = MainWindowController(model: model, errors: errors, confirms: confirms)
        wc.onCloseRequested = { [weak self] in
            self?.enterAccessoryMode()
        }
        mainController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 不让 macOS 在最后一个 window 关闭时自动退出 (我们窗口"关闭"实际是 hide)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出拦截: 有运行中 VM 时弹 confirm + 优雅停止. 不管 quit 从哪触发 (popover / cmd+Q / dock)
    /// 都走这里, 单一退出路径.
    ///
    /// 不用 .terminateLater — NSApplication 进入"等 reply"状态时 SwiftUI 的 mouse tracking /
    /// hover 在叠加层弹窗上会失效 (社区已知问题), dialog 按钮无响应. 改为立刻返回 .terminateCancel,
    /// 确认流程独立跑, 用户点"停止并退出"后用 quittingInProgress 标志再次 terminate(nil) 直放行.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quittingInProgress { return .terminateNow }
        if model.sessions.isEmpty { return .terminateNow }
        // 已有 confirm 在弹, 不重复触发 (用户连按 cmd+Q)
        if confirms.current != nil { return .terminateCancel }

        // 有运行中 VM: accessory mode 下 dialog 看不见, 先把主窗口拉回来
        exitAccessoryMode()
        statusPopover?.performClose(nil)

        let count = model.sessions.count
        confirms.present(ConfirmDialogModel(
            title: "退出 HVM",
            message: "还有 \(count) 个虚拟机在运行。继续退出会先发送 ACPI 关机信号 (最多等 10 秒), 超时未停的会被强制结束。",
            confirmTitle: "停止并退出",
            cancelTitle: "取消",
            destructive: true
        )) { [weak self] confirmed in
            guard let self, confirmed else { return }
            Task { @MainActor in
                await self.gracefulShutdownAll()
                self.quittingInProgress = true
                NSApp.terminate(nil)  // 二次进入 applicationShouldTerminate, 由 quittingInProgress 直放行
            }
        }
        return .terminateCancel
    }

    /// ACPI 优雅停所有 VM, 10s 超时后 force kill 残留. 在 main actor 跑因为 VMSession 都 @MainActor.
    private func gracefulShutdownAll() async {
        let sessions = Array(model.sessions.values)
        for s in sessions { try? s.requestStop() }

        // 轮询等所有 VM 进入 stopped 或超 10s
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let allStopped = model.sessions.values.allSatisfy { $0.state == .stopped }
            if allStopped { return }
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }

        // 残留 force kill (串行; 残留通常 0-1 个, 不值得为并行绕过 isolation checker)
        for s in model.sessions.values where s.state != .stopped {
            try? await s.forceStop()
        }
    }

    /// 双击 .hvmz 或 `open` 命令打开 bundle
    func application(_ application: NSApplication, open urls: [URL]) {
        // 如果当前在 accessory 模式, 切回 regular 让窗口可见
        exitAccessoryMode()
        for url in urls {
            guard url.pathExtension == "hvmz" else { continue }
            guard let config = try? BundleIO.load(from: url) else {
                errors.present(HVMError.bundle(.parseFailed(
                    reason: "无法解析 bundle", path: url.path
                )))
                continue
            }
            model.refreshList()
            model.selectedID = config.id
        }
    }

    // MARK: - menu bar mode

    private func enterAccessoryMode() {
        // 1. 切到 .accessory: Dock 图标隐藏, app 不显示在 cmd+tab
        NSApp.setActivationPolicy(.accessory)
        // 2. 创建状态栏图标 (idempotent)
        if statusItem == nil {
            createStatusItem()
        }
    }

    private func exitAccessoryMode() {
        // 1. 切回 .regular: Dock 图标显示
        NSApp.setActivationPolicy(.regular)
        // 2. 移除状态栏图标
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        // 3. 显示主窗口并 activate
        NSApp.activate(ignoringOtherApps: true)
        mainController?.showWindow(nil)
        mainController?.window?.makeKeyAndOrderFront(nil)
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 图标: 用 SF Symbol "shippingbox.fill" 表示 VM (cube 的 Apple 风变体)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "shippingbox.fill",
                                  accessibilityDescription: "HVM") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "HVM"
            }
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // popover 不预先建 contentViewController, 每次 show 时按 snapshot 重建
        let pop = NSPopover()
        pop.behavior = .transient   // 点外部自动关
        pop.animates = true
        statusPopover = pop
        statusItem = item
    }

    /// 点击 status item icon 触发: 已显示则关, 未显示则按当前 model snapshot 弹出
    @objc private func togglePopover(_ sender: Any?) {
        guard let pop = statusPopover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(nil)
            return
        }
        // 关键: sizingOptions=.preferredContentSize 让 NSHostingController 把 SwiftUI view
        // 的 fitting size 同步给 NSPopover. 没这行 popover 会用默认 size 导致位置漂移.
        let hc = NSHostingController(rootView: makePopoverView())
        hc.sizingOptions = .preferredContentSize
        pop.contentViewController = hc
        // accessory mode 下 popover 拿不到键盘焦点 — activate 一下
        NSApp.activate(ignoringOtherApps: true)
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// snapshot model + IP + 缩略图, 装配 SwiftUI view
    private func makePopoverView() -> MenuPopoverView {
        let running = model.list
            .compactMap { item -> AppModel.VMListItem? in
                guard model.sessions[item.id] != nil else { return nil }
                return item
            }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

        let rows = running.map { item in
            VMPopoverRowData(
                id: item.id,
                name: item.displayName,
                ip: ipForVM(item),
                thumbnail: thumbnailForVM(item),
                onTap: { [weak self] in self?.openVM(id: item.id) }
            )
        }
        return MenuPopoverView(
            rows: rows,
            onShowMain: { [weak self] in self?.menuShow() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// 取 VM 第一张网卡的 MAC, 查 host ARP 表
    private func ipForVM(_ item: AppModel.VMListItem) -> String? {
        guard let mac = item.config.networks.first?.macAddress else { return nil }
        return IPResolver.ipForMAC(mac)
    }

    /// 读 bundle/meta/thumbnail.png. 不存在返回 nil → SwiftUI 用 SF Symbol 占位
    private func thumbnailForVM(_ item: AppModel.VMListItem) -> NSImage? {
        let url = item.bundleURL
            .appendingPathComponent(BundleLayout.metaDirName)
            .appendingPathComponent(BundleLayout.thumbnailName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func openVM(id: UUID) {
        statusPopover?.performClose(nil)
        exitAccessoryMode()
        model.selectedID = id
    }

    @objc private func menuShow() {
        statusPopover?.performClose(nil)
        exitAccessoryMode()
    }
}

/// 启动 AppKit runloop
@MainActor
public enum HVMAppLauncher {
    public static func run() {
        let app = NSApplication.shared
        let delegate = HVMAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
