// HVMApp.swift (M2 AppKit shell + menu bar)
//
// X 关闭按钮不退出 app: hide window + 切到 NSApplication.activationPolicy(.accessory),
// Dock 图标隐藏, 系统右上角状态栏出现 HVM 图标 (NSStatusItem). 点 status item 弹出菜单
// 选 "Show HVM" 重新显示主窗口, 同时切回 .regular activation policy.
//
// 这样用户关闭主窗口后, sessions 里运行中的 VM 仍然在跑 (后台), 通过状态栏图标随时唤回.

import AppKit
import HVMBundle
import HVMCore

@MainActor
final class HVMAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let errors = ErrorPresenter()
    private var mainController: MainWindowController?
    private var statusItem: NSStatusItem?

    // MARK: - 应用生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        let wc = MainWindowController(model: model, errors: errors)
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
        }

        // 单击/右击都弹 menu
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show HVM",
                                   action: #selector(menuShow),
                                   keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit HVM",
                                   action: #selector(menuQuit),
                                   keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func menuShow() {
        exitAccessoryMode()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
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
