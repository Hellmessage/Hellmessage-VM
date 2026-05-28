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
import HVMGuiProbe

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

        // HDP-GUI probe server (HVM_GUI_PROBE=1 时 unix socket 接 hvm-dbg gui).
        // 老 GUI 在 HVMAppDelegate 启的; 新 GUI 也得启, 不然 hvm-dbg gui ping 连不上.
        // PR-C1 起新 GUI 接入自动化测试通路.
        ProbeServer.start()
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
    @State private var probeClickLog: String = "—"

    var body: some View {
        ZStack(alignment: .topLeading) {
            HVMTheme.color.bgBase
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                    headerBlock
                    togglesBlock
                    fieldsBlock
                    buttonsBlock
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

    // PR-C3 — HVMUI.Toggle + HVMUI.Checkbox (size + spring + indeterminate + probe)
    @State private var autoStart: Bool = true
    @State private var networkOn: Bool = false
    @State private var hostKeyboard: Bool = true
    @State private var hostMouse: Bool = false
    @State private var termsAccepted: Bool = false
    @State private var filterRunning: Bool = true
    @State private var selectAllPartial: Bool = false  // indeterminate demo

    private var togglesBlock: some View {
        sectionCard(title: "Toggle / Checkbox (PR-C3)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                // Toggle 三档 size + label/hint
                fieldRow("Toggle Sizes") {
                    HVMUI.Toggle("自动启动", isOn: $autoStart, size: .sm,
                                 probeID: "showcase.toggle.autostart.sm")
                    HVMUI.Toggle("自动启动", isOn: $autoStart,
                                 hint: "登录时自动启 VM", size: .md,
                                 probeID: "showcase.toggle.autostart.md")
                    HVMUI.Toggle("自动启动", isOn: $autoStart, size: .lg,
                                 probeID: "showcase.toggle.autostart.lg")
                }

                // Toggle 各种 binding 状态
                fieldRow("Toggle States") {
                    HVMUI.Toggle("启用网络", isOn: $networkOn,
                                 hint: networkOn ? "vmnet daemon 正在运行" : "未启",
                                 probeID: "showcase.toggle.network")
                    HVMUI.Toggle("Host Keyboard", isOn: $hostKeyboard,
                                 hint: "捕获主机键盘 (Cmd+Opt 退出)",
                                 probeID: "showcase.toggle.keyboard")
                    HVMUI.Toggle("Host Mouse", isOn: $hostMouse,
                                 hint: "Disabled 演示", disabled: true)
                }

                // Checkbox 三档 size
                fieldRow("Checkbox Sizes") {
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .sm,
                                   probeID: "showcase.checkbox.filter.sm")
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .md,
                                   probeID: "showcase.checkbox.filter.md")
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .lg,
                                   probeID: "showcase.checkbox.filter.lg")
                }

                // Checkbox indeterminate + disabled
                fieldRow("Checkbox States") {
                    HVMUI.Checkbox("我同意条款", isOn: $termsAccepted,
                                   probeID: "showcase.checkbox.terms")
                    HVMUI.Checkbox("全选 (半选)", isOn: $selectAllPartial,
                                   indeterminate: true,
                                   probeID: "showcase.checkbox.selectall.indeterminate")
                    HVMUI.Checkbox("Disabled", isOn: .constant(true),
                                   disabled: true)
                }

                // probe 反馈
                HStack(spacing: HVMTheme.space.sm) {
                    Text("hvm-dbg gui click --identifier showcase.toggle.network")
                        .font(HVMTheme.font.monoSm)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                    Text("network: \(networkOn ? "on" : "off")")
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(networkOn ? HVMTheme.color.success
                                                   : HVMTheme.color.textTertiary)
                }
            }
        }
    }

    // PR-C2 — HVMTextField + HVMSecureField (size + state 完备 + a11y + probe)
    @State private var vmName: String = ""
    @State private var cpuCount: String = "4"
    @State private var ipsw: String = ""
    @State private var password: String = ""
    @State private var simulateLoading: Bool = false

    private var fieldsBlock: some View {
        sectionCard(title: "TextField / SecureField (PR-C2)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                // 三档 size
                fieldRow("Sizes (.sm / .md / .lg)") {
                    HVMUI.TextField("名称", text: $vmName, placeholder: "我的 VM",
                                 size: .sm, probeID: "showcase.field.name.sm")
                        .frame(maxWidth: 200)
                    HVMUI.TextField("名称", text: $vmName, placeholder: "我的 VM",
                                 size: .md, probeID: "showcase.field.name.md")
                        .frame(maxWidth: 240)
                    HVMUI.TextField("名称", text: $vmName, placeholder: "我的 VM",
                                 size: .lg, probeID: "showcase.field.name.lg")
                        .frame(maxWidth: 280)
                }

                // icon + suffix
                fieldRow("Icon + Suffix") {
                    HVMUI.TextField("CPU", text: $cpuCount, placeholder: "4",
                                 icon: "cpu", suffix: "核",
                                 probeID: "showcase.field.cpu")
                        .frame(maxWidth: 200)
                    HVMUI.TextField("IPSW", text: $ipsw, placeholder: "选择固件路径...",
                                 icon: "doc.badge.arrow.up",
                                 probeID: "showcase.field.ipsw")
                        .frame(maxWidth: 320)
                }

                // 错误 + loading + disabled
                fieldRow("States") {
                    HVMUI.TextField("Error", text: $vmName, placeholder: "至少 1 字符",
                                 errorMessage: vmName.isEmpty ? "VM 名称不能为空" : nil,
                                 probeID: "showcase.field.error")
                        .frame(maxWidth: 240)
                    HVMUI.TextField("Loading", text: $cpuCount, placeholder: "validating...",
                                 isLoading: true,
                                 probeID: "showcase.field.loading")
                        .frame(maxWidth: 200)
                    HVMUI.TextField("Disabled", text: .constant("read-only"),
                                 placeholder: "", disabled: true)
                        .frame(maxWidth: 200)
                }

                // SecureField 带 toggle
                fieldRow("SecureField") {
                    HVMUI.SecureField("密码", text: $password,
                                   placeholder: "至少 8 字符",
                                   showToggle: true,
                                   errorMessage: password.count > 0 && password.count < 8
                                       ? "密码至少 8 字符" : nil,
                                   probeID: "showcase.field.password")
                        .frame(maxWidth: 320)
                }

                // probe 反馈
                HStack(spacing: HVMTheme.space.sm) {
                    Text("hvm-dbg gui type --identifier showcase.field.name.md --text foo")
                        .font(HVMTheme.font.monoSm)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                    Text("当前 name: \(vmName.isEmpty ? "—" : vmName)")
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.accent)
                }
            }
        }
    }

    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
            Text(label)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HStack(alignment: .top, spacing: HVMTheme.space.md) {
                content()
            }
        }
    }

    // PR-C1 — 5 variant + hover/press/disabled + icon + probe
    private var buttonsBlock: some View {
        sectionCard(title: "Buttons (PR-C1)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                buttonRow("Variants") {
                    HVMUI.Button("Primary", variant: .primary,
                              probeID: "showcase.button.primary") { probeClickLog = "primary" }
                    HVMUI.Button("Secondary", variant: .secondary,
                              probeID: "showcase.button.secondary") { probeClickLog = "secondary" }
                    HVMUI.Button("Ghost", variant: .ghost,
                              probeID: "showcase.button.ghost") { probeClickLog = "ghost" }
                    HVMUI.Button("Destructive", variant: .destructive,
                              probeID: "showcase.button.destructive") { probeClickLog = "destructive" }
                    HVMUI.Button(icon: "gear", variant: .icon,
                              probeID: "showcase.button.icon") { probeClickLog = "icon" }
                }

                buttonRow("With icon") {
                    HVMUI.Button("Create VM", variant: .primary, icon: "plus") { }
                    HVMUI.Button("Delete", variant: .destructive, icon: "trash") { }
                    HVMUI.Button("Settings", variant: .ghost, icon: "gearshape") { }
                }

                buttonRow("Disabled") {
                    HVMUI.Button("Primary", variant: .primary, disabled: true) { }
                    HVMUI.Button("Secondary", variant: .secondary, disabled: true) { }
                    HVMUI.Button("Destructive", variant: .destructive, disabled: true) { }
                    HVMUI.Button(icon: "gear", variant: .icon, disabled: true) { }
                }

                HStack(spacing: HVMTheme.space.sm) {
                    Text("hvm-dbg gui click --identifier showcase.button.primary")
                        .font(HVMTheme.font.monoSm)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                    Text("最近: \(probeClickLog)")
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.accent)
                }
            }
        }
    }

    private func buttonRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
            Text(label)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HStack(spacing: HVMTheme.space.md) {
                content()
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
