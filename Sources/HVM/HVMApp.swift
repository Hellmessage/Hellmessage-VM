// HVM 主 App (M0/M1 骨架)
// SwiftUI 空窗口 + 黑色主题 + 中央版本号展示
// 详见 docs/GUI.md
//
// M1 起 HVM 可执行文件有两个模式:
//   1. 默认 (本文件 HVMApp): GUI 模式, 打开主窗口
//   2. --host-mode-bundle <path>: VMHost 模式, 不开窗口, 承载 VZVirtualMachine
//      分派逻辑在 main.swift

import SwiftUI
import HVMCore

public struct HVMApp: App {
    public init() {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    public var body: some Scene {
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
