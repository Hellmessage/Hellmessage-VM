// HVM 主 App (M0 骨架)
// SwiftUI 空窗口 + 黑色主题 + 中央版本号展示
// 详见 docs/GUI.md

import SwiftUI
import HVMCore

@main
struct HVMApp: App {
    init() {
        // 锁定深色外观, 不跟随系统主题 (docs/GUI.md)
        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup("HVM") {
            M0SkeletonView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1020, minHeight: 750)
        }
        .windowResizability(.contentMinSize)
    }
}

/// M0 骨架视图: 纯黑背景, 中央单行等宽字版本号
struct M0SkeletonView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text(HVMVersion.displayString)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(white: 0.94))
        }
    }
}
