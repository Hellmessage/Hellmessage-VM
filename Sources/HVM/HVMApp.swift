// HVMApp.swift (M2 AppKit shell)
// 不再用 SwiftUI App + WindowGroup, 改为 NSApplicationDelegate + MainWindowController.
// 原因: VZVirtualMachineView 需要稳定 NSWindow hierarchy, SwiftUI NSViewRepresentable
// 会在 body re-render 时对承载的 NSView 做 detach/reattach, 导致 VZ Metal drawable 失效.
// 参考 Apple Virtualization sample 也都使用 AppKit 管理 VZ view.

import AppKit
import HVMBundle
import HVMCore

@MainActor
final class HVMAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let errors = ErrorPresenter()
    private var mainController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        let wc = MainWindowController(model: model, errors: errors)
        mainController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 双击 .hvmz 或 `open` 命令打开 bundle
    func application(_ application: NSApplication, open urls: [URL]) {
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
