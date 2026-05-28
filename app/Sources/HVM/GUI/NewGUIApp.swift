// NewGUIApp.swift — 新 GUI 主入口 (重构占位)
//
// 编译开关: 仅 `make build GUI=new` (透传 -Xswiftc -DNEW_GUI) 时整文件参与编译.
// 老 GUI (app/Sources/HVM/UI/**) 一行不动, 默认构建仍走 HVMAppLauncher.
//
// 这里只放最小 AppKit shell + 一个 SwiftUI "新 GUI 开发中" 窗口, 让新 GUI 有起点;
// 后续按 docs/v3/ 设计稿往 GUI/ 子目录下补 Content / Dialogs / Style 等模块.

#if NEW_GUI

import AppKit
import SwiftUI

@MainActor
final class NewGUIAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        // NSHostingController 默认会让 window 跟随 SwiftUI 视图 intrinsic size — 没固定 frame
        // 的 root view 会让窗口塌到内容最小尺寸 (实测 1×64). 必须显式 setContentSize, 同时
        // root view 自己也兜底 frame 防止 contentViewController= 赋值时再次自适应.
        let host = NSHostingController(rootView: NewGUIRootView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "HVM (新 GUI)"
        win.contentViewController = host
        win.setContentSize(NSSize(width: 1080, height: 720))
        win.minSize = NSSize(width: 1080, height: 720)
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// 启动 AppKit runloop (新 GUI 路径)
@MainActor
public enum NewGUIAppLauncher {
    public static func run() {
        let app = NSApplication.shared
        let delegate = NewGUIAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private struct NewGUIRootView: View {
    var body: some View {
        ZStack {
            // 中性深灰 #18181B 主底 (CLAUDE.md GUI 约束)
            Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1B / 255)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("HVM")
                    .font(.system(size: 48, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                Text("新 GUI 开发中")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                Text("app/Sources/HVM/GUI/")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        // 不加 frame 时 NSHostingController 会把 window content size 拉到 VStack 内
        // 容最小尺寸 (实测 1×64). 这里给个保底初始尺寸 + minWidth/minHeight, NSWindow
        // setContentSize 之后再让用户拖动 resize.
        .frame(minWidth: 800, idealWidth: 1080, minHeight: 560, idealHeight: 720)
    }
}

#endif
