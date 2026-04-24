// HVM 主 App (M2)
// 黑色主题, NavigationSplitView, 挂 AppModel + ErrorPresenter 做环境对象

import SwiftUI
import HVMCore

public struct HVMApp: App {
    @State private var model = AppModel()
    @State private var errors = ErrorPresenter()

    public init() {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    public var body: some Scene {
        WindowGroup("HVM") {
            MainContentView(model: model, errors: errors)
                .frame(minWidth: 1020, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // 退出时最后一次刷新 VMs (独立窗口关闭在各 VMSession.cleanup 处理)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 720)
    }
}
