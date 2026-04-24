// HVM 主 App (M2)
// 黑色主题, 持 AppModel + ErrorPresenter, 处理双击 .hvmz 打开

import SwiftUI
import HVMBundle
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
                .frame(minWidth: 1020, minHeight: 720)
                .onOpenURL { url in
                    handleOpen(url: url)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 720)
    }

    /// 双击 .hvmz 或 open 命令打开: 定位/加入列表并选中
    private func handleOpen(url: URL) {
        guard url.pathExtension == "hvmz" else { return }
        guard let config = try? BundleIO.load(from: url) else {
            errors.present(HVMError.bundle(.parseFailed(
                reason: "无法解析 bundle", path: url.path
            )))
            return
        }
        model.refreshList()
        model.selectedID = config.id
    }
}
