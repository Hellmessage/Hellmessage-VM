// NewGUIApp.swift — 新 GUI 主入口 + Theme token 演示页 (PR-T1 + T2)
//
// 编译开关: 仅 `make build GUI=new` (透传 -Xswiftc -DNEW_GUI) 时整文件参与编译.
// 老 GUI (app/Sources/HVM/UI/**) 一行不动, 默认构建仍走 HVMAppLauncher.
//
// 目前页面是 Theme token 演示卡片 (色板 / 字号 / spacing / radius / accent),
// 给设计稿 docs/v3/NEW_GUI.md PR-T1 + T2 验收用. 后续 PR-C* 落基础组件时,
// 这里逐步替换为业务页 (sidebar + detail) 骨架, 演示页留 Components Showcase 子稿.

#if NEW_GUI

import AppKit
import SwiftUI

@MainActor
final class NewGUIAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        // 锁定最小尺寸三件套 (单写 win.minSize 不够, 三条都要):
        //   1. root view .frame(minWidth:, minHeight:) — SwiftUI 层声明最小
        //   2. host.sizingOptions = .minSize — macOS 13+ 让 hostingController 把 SwiftUI
        //      minWidth/minHeight 自动同步到 window.contentMinSize
        //   3. win.contentMinSize = ... — 直接锁 content 区下限 (不含标题栏); 双保险
        // 不用 win.minSize: 它含 28px 标题栏, 设 1080×720 时 content 仍能压到 1080×692.
        let host = NSHostingController(rootView: NewGUIRootView())
        host.sizingOptions = .minSize
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "HVM (新 GUI)"
        win.contentViewController = host
        win.setContentSize(NSSize(width: 1080, height: 720))
        win.contentMinSize = NSSize(width: 1080, height: 720)
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

// MARK: - Root + Theme 演示页

private struct NewGUIRootView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            HVMTheme.color.bgBase
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                    headerBlock
                    colorPaletteBlock
                    typographyBlock
                    spacingBlock
                    radiusBlock
                    motionBlock
                    footerBlock
                }
                .padding(HVMTheme.space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 1080, idealWidth: 1080, minHeight: 720, idealHeight: 720)
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
            Text("HVM")
                .font(HVMTheme.font.xl)
                .foregroundStyle(HVMTheme.color.textPrimary)
            HStack(spacing: HVMTheme.space.sm) {
                Text("Theme Token Showcase")
                    .font(HVMTheme.font.md)
                    .foregroundStyle(HVMTheme.color.textSecondary)
                Text("PR-T1 + T2")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.accent)
                    .padding(.horizontal, HVMTheme.space.sm)
                    .padding(.vertical, HVMTheme.space.xs)
                    .background(HVMTheme.color.accentMuted)
                    .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.sm))
            }
        }
    }

    // 色板 — 横排 swatch
    private var colorPaletteBlock: some View {
        sectionCard(title: "Colors") {
            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                swatchRow("Background", swatches: [
                    ("bgBase",    HVMTheme.color.bgBase),
                    ("bgRaised",  HVMTheme.color.bgRaised),
                    ("bgOverlay", HVMTheme.color.bgOverlay)
                ])
                swatchRow("Accent", swatches: [
                    ("accent",       HVMTheme.color.accent),
                    ("accentHover",  HVMTheme.color.accentHover),
                    ("accentMuted",  HVMTheme.color.accentMuted)
                ])
                swatchRow("Status", swatches: [
                    ("success", HVMTheme.color.success),
                    ("warn",    HVMTheme.color.warn),
                    ("error",   HVMTheme.color.error),
                    ("info",    HVMTheme.color.info)
                ])
            }
        }
    }

    private func swatchRow(_ label: String, swatches: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
            Text(label)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HStack(spacing: HVMTheme.space.md) {
                ForEach(swatches, id: \.0) { item in
                    VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
                        RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                            .fill(item.1)
                            .frame(width: 96, height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                                    .stroke(HVMTheme.color.borderDefault,
                                            lineWidth: HVMTheme.border.hairline)
                            )
                        Text(item.0)
                            .font(HVMTheme.font.xs)
                            .foregroundStyle(HVMTheme.color.textTertiary)
                    }
                }
            }
        }
    }

    // 字号节奏
    private var typographyBlock: some View {
        sectionCard(title: "Typography") {
            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                typoRow("xl (24, semibold)",   font: HVMTheme.font.xl)
                typoRow("lg (18, semibold)",   font: HVMTheme.font.lg)
                typoRow("md (14, medium)",     font: HVMTheme.font.md)
                typoRow("base (13, regular)",  font: HVMTheme.font.base)
                typoRow("sm (12, regular)",    font: HVMTheme.font.sm)
                typoRow("xs (11, regular)",    font: HVMTheme.font.xs)
                typoRow("mono (13, mono)",     font: HVMTheme.font.mono)
            }
        }
    }

    private func typoRow(_ label: String, font: Font) -> some View {
        HStack(spacing: HVMTheme.space.lg) {
            Text("HVM 虚拟机")
                .font(font)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .frame(minWidth: 160, alignment: .leading)
            Text(label)
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
        }
    }

    // 间距 — 横向 bar 长度差
    private var spacingBlock: some View {
        sectionCard(title: "Spacing (4-pt grid)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                ForEach([
                    ("xs",   HVMTheme.space.xs),
                    ("sm",   HVMTheme.space.sm),
                    ("md",   HVMTheme.space.md),
                    ("lg",   HVMTheme.space.lg),
                    ("xl",   HVMTheme.space.xl),
                    ("xxl",  HVMTheme.space.xxl),
                    ("xxxl", HVMTheme.space.xxxl)
                ], id: \.0) { item in
                    HStack(spacing: HVMTheme.space.md) {
                        Text(item.0)
                            .font(HVMTheme.font.xs)
                            .foregroundStyle(HVMTheme.color.textTertiary)
                            .frame(width: 36, alignment: .leading)
                        RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                            .fill(HVMTheme.color.accent)
                            .frame(width: item.1, height: 8)
                        Text("\(Int(item.1))pt")
                            .font(HVMTheme.font.xs)
                            .foregroundStyle(HVMTheme.color.textTertiary)
                    }
                }
            }
        }
    }

    // 圆角档位
    private var radiusBlock: some View {
        sectionCard(title: "Radius") {
            HStack(spacing: HVMTheme.space.lg) {
                radiusSwatch("sm (4)", radius: HVMTheme.radius.sm)
                radiusSwatch("md (6)", radius: HVMTheme.radius.md)
                radiusSwatch("lg (8)", radius: HVMTheme.radius.lg)
                radiusSwatch("xl (12)", radius: HVMTheme.radius.xl)
            }
        }
    }

    private func radiusSwatch(_ label: String, radius: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
            RoundedRectangle(cornerRadius: radius)
                .fill(HVMTheme.color.bgRaised)
                .frame(width: 96, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(HVMTheme.color.borderDefault,
                                lineWidth: HVMTheme.border.hairline)
                )
            Text(label)
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
        }
    }

    // 动效占位 — hover 改 bg 验三档时长感
    private var motionBlock: some View {
        sectionCard(title: "Motion") {
            HStack(spacing: HVMTheme.space.md) {
                MotionDemoTile(label: "fast (120ms)", animation: HVMTheme.motion.easeOutFast)
                MotionDemoTile(label: "base (200ms)", animation: HVMTheme.motion.easeOut)
                MotionDemoTile(label: "slow (320ms)", animation: HVMTheme.motion.easeOutSlow)
            }
        }
    }

    private var footerBlock: some View {
        HStack(spacing: HVMTheme.space.sm) {
            Text("docs/v3/NEW_GUI.md")
                .font(HVMTheme.font.monoSm)
                .foregroundStyle(HVMTheme.color.textTertiary)
            Spacer()
            Text("accent = #06B6D4")
                .font(HVMTheme.font.monoSm)
                .foregroundStyle(HVMTheme.color.accent)
        }
        .padding(.top, HVMTheme.space.md)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text(title)
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textPrimary)
            content()
        }
        .padding(HVMTheme.space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HVMTheme.color.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                .stroke(HVMTheme.color.borderDefault,
                        lineWidth: HVMTheme.border.hairline)
        )
    }
}

/// hover 触发 bg 切换 — 验动效 token 实际时长感觉.
private struct MotionDemoTile: View {
    let label: String
    let animation: Animation
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .fill(hovered ? HVMTheme.color.accent : HVMTheme.color.bgOverlay)
                .frame(width: 120, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                        .stroke(HVMTheme.color.borderDefault,
                                lineWidth: HVMTheme.border.hairline)
                )
                .animation(animation, value: hovered)
                .onHover { hovered = $0 }
            Text(label)
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
        }
    }
}

#endif
