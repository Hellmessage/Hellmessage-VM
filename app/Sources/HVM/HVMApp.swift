// HVMApp.swift (M2 AppKit shell + menu bar)
//
// X 关闭按钮不退出 app: hide window + 切到 NSApplication.activationPolicy(.accessory),
// Dock 图标隐藏. menu bar 图标 (NSStatusItem) 在 applicationDidFinishLaunching 就创建,
// 与窗口可见性无关 — 用户启动 App 时 menu bar 立刻能看到 HVM 图标, 关闭主窗口后图标继续在.
// 点 status item 弹出菜单选 "Show HVM" 重新显示主窗口, 同时切回 .regular activation policy.
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
    /// 用户主动请求真退出 (走 popover 退出按钮). 否则 Cmd+Q / Dock Quit 都视为"hide 到 menu bar"
    private var realQuitRequested = false

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        // 启动时杜绝上一次 GUI 异常死亡留下的孤儿 QEMU/swtpm 进程 + stale socket.
        // 必须在 model.refreshList / 主窗口加载之前: VM list 探测 BundleLock 时, 孤儿
        // 已被清掉, isBusy 报告才准确. 同步调用, 一般 < 200ms 不阻塞 UI.
        OrphanReaper.reapOnLaunch()

        // 让 detached QEMU 窗口里的错误弹窗复用主窗口同一份 presenter,
        // ErrorDialog 仍只在主窗口 DialogOverlay 出现, 体验跟嵌入路径一致.
        model.sharedErrors = errors

        installMainMenu()

        // menu bar 图标启动即创建, 跟主窗口可见性独立 — 用户打开 App 立刻能在右上角看到
        createStatusItem()

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

        // 非真退出请求 (Cmd+Q / Dock Quit) → 视作"关闭主窗口, 留在 menu bar"
        // 走 window.performClose → windowShouldClose → enterAccessoryMode, 与 X 按钮同流程
        if !realQuitRequested {
            if let win = mainController?.window, win.isVisible {
                win.performClose(nil)
            }
            return .terminateCancel
        }
        // 真退出走完原 confirm 流程后, 标志即重置, 防下次 Cmd+Q 误用
        realQuitRequested = false

        if model.sessions.isEmpty { return .terminateNow }
        // 已有 confirm 在弹, 不重复触发 (用户连按)
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

        // 轮询等所有 VM 进入 stopped 或超 HVMTimeout.gracefulShutdown
        let deadline = Date().addingTimeInterval(HVMTimeout.gracefulShutdown)
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
        // 切到 .accessory: Dock 图标隐藏, app 不显示在 cmd+tab.
        // status item 在 applicationDidFinishLaunching 已经建好, 这里不重复.
        NSApp.setActivationPolicy(.accessory)
    }

    private func exitAccessoryMode() {
        // 1. 切回 .regular: Dock 图标显示 (status item 保持存在, 不动)
        NSApp.setActivationPolicy(.regular)
        // 2. 显示主窗口并 activate
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
        // 走 item.runState (BundleLock 探测) 而不是 sessions[] (后者只含 VZ 通路本进程
        // session, QEMU 后端跑在 host 子进程不入 sessions, hvm-cli 起的 VM 也不入).
        let running = model.list
            .filter { $0.runState == "running" }
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
            onQuit: { [weak self] in self?.requestRealQuit() }
        )
    }

    /// 取 VM 第一张网卡的 MAC, 查 host ARP 表
    private func ipForVM(_ item: AppModel.VMListItem) -> String? {
        guard let mac = item.config.networks.first?.macAddress else { return nil }
        return IPResolver.ipForMAC(mac)
    }

    /// 读 bundle/meta/thumbnail.png. 走 ThumbnailCache (LRU + mtime 失效),
    /// 多 VM 时 popover 弹出零 IO 抖动.
    private func thumbnailForVM(_ item: AppModel.VMListItem) -> NSImage? {
        let url = item.bundleURL
            .appendingPathComponent(BundleLayout.metaDirName)
            .appendingPathComponent(BundleLayout.thumbnailName)
        return ThumbnailCache.shared.image(for: url)
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

    /// popover "退出 HVM" 按钮入口. 标记真退出意图后再走 NSApp.terminate, 避免被
    /// applicationShouldTerminate 顶部的 hide 分支拦截
    private func requestRealQuit() {
        realQuitRequested = true
        NSApp.terminate(nil)
    }

    // MARK: - main menu

    /// 手写 NSApplication 启动不会自动建 mainMenu, Cmd+Q 等快捷键无人响应会发出 NSBeep.
    /// 这里补最少必要项: Application menu (Hide/Quit) + Window menu (Cmd+W 关窗 / 最小化).
    /// Quit 仍走 NSApp.terminate, 由 applicationShouldTerminate 的 hide 分支拦截.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu (系统会用 CFBundleName 作显示名)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide HVM",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                          action: #selector(NSApplication.hideOtherApplications(_:)),
                                          keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit HVM",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Window menu: 最小化 + 关窗 (Cmd+W 走 windowShouldClose → hide 流程, 与 X 按钮一致)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
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
