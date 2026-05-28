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
        // PR-D1: .hvmDialogHost() 套在 NSHostingController root view 外层 —
        // 作为 NewGUIRootView 的真正祖先, 让 NewGUIRootView 内部 @EnvironmentObject
        // 能拿到 DialogPresenter.
        let host = NSHostingController(rootView: NewGUIRootView().hvmDialogHost())
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
    // PR-D1: @EnvironmentObject 拿 dialog presenter. .hvmDialogHost() 在
    // NSHostingController root view 外层套 (NewGUIAppDelegate), 是 NewGUIRootView
    // 的祖先, environment 注入有效.
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    @State private var probeClickLog: String = "—"

    var body: some View {
        ZStack(alignment: .topLeading) {
            HVMTheme.color.bgBase
                .ignoresSafeArea()

            ScrollView {
                // 反向 zIndex (上→下递减) — 让上面 sectionCard 内的 Select popover
                // .overlay 视觉上浮在下方 sectionCard 之上, 不被默认 VStack 后绘
                // 顺序压住. 治标方案; PR-D1 OverlayContainer 后用 root-level
                // ZStack 渲染浮窗, 彻底解决.
                //
                // 节顺序 (C8 整理): 从直接看到的视觉 (header) → 用户最常用的
                // 交互组件 (操作类/输入类/复杂类) → 装饰类 (icon/tooltip) →
                // Theme token 参考 (放最下面给"我想知道色板/字号" 时查).
                VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                    headerBlock.zIndex(140)
                    dialogDemoBlock.zIndex(135)
                    // 交互组件 — 业务页主战场
                    buttonsBlock.zIndex(130)
                    fieldsBlock.zIndex(120)
                    togglesBlock.zIndex(110)
                    selectsBlock.zIndex(100)
                    // 容器 + 装饰
                    sectionsBlock.zIndex(90)
                    iconsBlock.zIndex(80)
                    // Theme token 参考 (色板/字号/spacing/radius/motion)
                    colorPaletteBlock.zIndex(60)
                    typographyBlock.zIndex(50)
                    spacingBlock.zIndex(40)
                    radiusBlock.zIndex(30)
                    motionBlock.zIndex(20)
                    footerBlock.zIndex(10)
                }
                .padding(HVMTheme.space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // PR-D1 OverlayContainer: .hvmDialogHost() 套外层在 NSHostingController
        // 创建时 (NewGUIRootView().hvmDialogHost()), NewGUIRootView 自己可以
        // @EnvironmentObject 拿 dialog.
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
        sectionCard(title: "Colors",
                    description: "Theme token 色板 — 业务侧禁直写 Color(red:), 一律走 HVMTheme.color.<name>") {
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
        sectionCard(title: "Typography",
                    description: "字号节奏严格 11/12/13/14/18/24, 不留中间值. mono 仅用于 UUID/MAC/路径") {
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
        sectionCard(title: "Spacing (4-pt grid)",
                    description: "Linear 同款 4-pt grid. 业务侧禁直写 .padding(8) 等硬数字, 走 HVMTheme.space") {
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
        sectionCard(title: "Radius",
                    description: "圆角 4 档: sm (badge) / md (字段) / lg (Section) / xl (Dialog)") {
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
        sectionCard(title: "Motion",
                    description: "时长三档: fast (120ms hover) / base (200ms focus) / slow (320ms 切页). Hover 试试 ↓") {
            HStack(spacing: HVMTheme.space.md) {
                MotionDemoTile(label: "fast (120ms)", animation: HVMTheme.motion.easeOutFast)
                MotionDemoTile(label: "base (200ms)", animation: HVMTheme.motion.easeOut)
                MotionDemoTile(label: "slow (320ms)", animation: HVMTheme.motion.easeOutSlow)
            }
        }
    }

    // PR-C4 — HVMUI.Select (下拉 + 搜索 + 键盘导航 + probe)
    enum DemoEngine: Hashable { case vz, qemu }
    @State private var engineSelection: DemoEngine? = .vz
    @State private var isoSelection: String? = nil
    @State private var cpuSelection: Int = 4

    private var selectsBlock: some View {
        sectionCard(title: "Select (PR-C4)",
                    description: "自绘下拉, 不用 SwiftUI .popover. generic value + 搜索 + 键盘 ↑↓Enter + 互斥打开 + 派生 probe id") {
            // 反向 zIndex 让上面 fieldRow 的 Select popover 浮在下方 fieldRow 之上.
            // 治标方案; PR-D1 OverlayContainer 彻底解决.
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                fieldRow("Basic") {
                    HVMUI.Select(
                        "引擎",
                        selection: $engineSelection,
                        options: [
                            .init(value: .vz,   label: "VZ",   hint: "Apple 原生 (推荐)",
                                  icon: "applelogo"),
                            .init(value: .qemu, label: "QEMU", hint: "Windows ARM64",
                                  icon: "cpu")
                        ],
                        probeID: "showcase.select.engine"
                    )
                    .frame(maxWidth: 280)

                    HVMUI.Select(
                        "CPU",
                        selection: $cpuSelection,
                        options: (1...16).map {
                            .init(value: $0, label: "\($0) 核")
                        },
                        probeID: "showcase.select.cpu"
                    )
                    .frame(maxWidth: 160)
                }
                .zIndex(40)

                // searchable + 大量选项
                fieldRow("Searchable (10 ISO)") {
                    HVMUI.Select(
                        "ISO 镜像",
                        selection: $isoSelection,
                        options: [
                            .init(value: "ubuntu-24.04-arm64.iso",     label: "Ubuntu 24.04 LTS"),
                            .init(value: "ubuntu-22.04-arm64.iso",     label: "Ubuntu 22.04 LTS"),
                            .init(value: "debian-12-arm64.iso",        label: "Debian 12"),
                            .init(value: "fedora-40-arm64.iso",        label: "Fedora 40"),
                            .init(value: "alpine-3.20-arm64.iso",      label: "Alpine 3.20"),
                            .init(value: "archlinux-arm64.iso",        label: "Arch Linux"),
                            .init(value: "openSUSE-leap-15.6.iso",     label: "openSUSE Leap 15.6"),
                            .init(value: "rocky-9-arm64.iso",          label: "Rocky Linux 9"),
                            .init(value: "centos-stream-9-arm64.iso",  label: "CentOS Stream 9"),
                            .init(value: "kali-2024.3-arm64.iso",      label: "Kali Linux 2024.3")
                        ],
                        placeholder: "选择 ISO 镜像...",
                        size: .md,
                        icon: "opticaldisc",
                        searchable: true,
                        probeID: "showcase.select.iso"
                    )
                    .frame(maxWidth: 320)
                }
                .zIndex(30)

                fieldRow("States") {
                    HVMUI.Select(
                        "错误态",
                        selection: $engineSelection,
                        options: [.init(value: .vz, label: "VZ")],
                        errorMessage: "未配置启动引擎",
                        probeID: "showcase.select.error"
                    )
                    .frame(maxWidth: 240)

                    HVMUI.Select(
                        "加载中",
                        selection: $engineSelection,
                        options: [],
                        placeholder: "拉取选项...",
                        isLoading: true,
                        probeID: "showcase.select.loading"
                    )
                    .frame(maxWidth: 200)

                    HVMUI.Select(
                        "Disabled",
                        selection: .constant(DemoEngine.vz),
                        options: [.init(value: .vz, label: "VZ")],
                        disabled: true,
                        probeID: "showcase.select.disabled"
                    )
                    .frame(maxWidth: 200)
                }
                .zIndex(20)

                HStack(spacing: HVMTheme.space.sm) {
                    Text("hvm-dbg gui type --identifier showcase.select.engine --text QEMU")
                        .font(HVMTheme.font.monoSm)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                    Text("engine: \(engineSelection.map { String(describing: $0) } ?? "—")")
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.accent)
                }
                .zIndex(10)
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
        sectionCard(title: "Toggle / Checkbox (PR-C3)",
                    description: "3 档 size + spring 切换 + indeterminate 半选态 + disabled 灰化用 bgDisabled token") {
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
                                 hint: "Disabled 演示", disabled: true,
                                 probeID: "showcase.toggle.mouse.disabled")
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
                                   disabled: true,
                                   probeID: "showcase.checkbox.disabled")
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
        sectionCard(title: "TextField / SecureField (PR-C2)",
                    description: "3 档 size + 7 状态 (empty/filled/focused/hover/error/loading/disabled) + focus ring 渐现 + 共享 FieldChrome modifier") {
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
                                 placeholder: "", disabled: true,
                                 probeID: "showcase.field.disabled")
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

    // PR-D1 — OverlayContainer demo (DialogHost + DialogPresenter)
    private var dialogDemoBlock: some View {
        sectionCard(title: "OverlayContainer (PR-D1)",
                    description: "全局 dialog 渲染容器 — popover 渲染到 root-level ZStack, 脱离 ScrollView/sectionCard 层级限制. AlertDialog/Confirm/Input/Wizard 后续 D3-D6 落地") {
            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                fieldRow("Try it") {
                    HVMUI.Button("打开简单 Dialog", variant: .primary,
                                 probeID: "showcase.dialog.show") {
                        dialog.present { handle in
                            SimpleDialogCard(
                                handle: handle,
                                title: "Hello!",
                                message: "这是一个 PR-D1 OverlayContainer demo dialog. 渲染在 root-level ZStack, 完全脱离 ScrollView clip 和 sectionCard 层级."
                            )
                        }
                    }

                    HVMUI.Button("嵌套 Dialog", variant: .secondary,
                                 probeID: "showcase.dialog.nested") {
                        dialog.present { outerHandle in
                            SimpleDialogCard(
                                handle: outerHandle,
                                title: "外层",
                                message: "栈结构支持嵌套. 点'再开一个'看栈顶覆盖效果.",
                                extraLabel: "再开一个",
                                extraProbeID: "showcase.dialog.nested.inner",
                                extraAction: {
                                    dialog.present { innerHandle in
                                        SimpleDialogCard(
                                            handle: innerHandle,
                                            title: "内层",
                                            message: "栈顶 dialog 覆盖外层. 关闭内层后外层仍在."
                                        )
                                    }
                                }
                            )
                        }
                    }

                    HVMUI.Button("关闭所有", variant: .ghost,
                                 probeID: "showcase.dialog.dismissAll") {
                        dialog.dismissAll()
                    }
                }

                Text("hvm-dbg gui click showcase.dialog.show → 打开 dialog (zIndex 浮在 sectionCard / Buttons 节之上)")
                    .font(HVMTheme.font.monoSm)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
        }
    }

    // PR-C6 — HVMUI.Icon / KbdHint / Tooltip (辅助组件)
    private var iconsBlock: some View {
        sectionCard(title: "Icon / KbdHint / Tooltip (PR-C6)",
                    description: "辅助组件: Icon 包装 SF Symbol (5 size + 9 color), KbdHint 快捷键 chip (typed Key enum), Tooltip 自绘 hover 500ms delay") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                // Icon sizes
                fieldRow("Icon sizes (.xs / .sm / .md / .lg / .xl)") {
                    HVMUI.Icon("gear", size: .xs)
                    HVMUI.Icon("gear", size: .sm)
                    HVMUI.Icon("gear", size: .md)
                    HVMUI.Icon("gear", size: .lg)
                    HVMUI.Icon("gear", size: .xl)
                }

                // Icon colors
                fieldRow("Icon colors") {
                    HVMUI.Icon("checkmark.circle.fill", size: .lg, color: .success)
                    HVMUI.Icon("exclamationmark.triangle.fill", size: .lg, color: .warn)
                    HVMUI.Icon("xmark.circle.fill", size: .lg, color: .error)
                    HVMUI.Icon("info.circle.fill", size: .lg, color: .info)
                    HVMUI.Icon("sparkles", size: .lg, color: .accent)
                    HVMUI.Icon("ellipsis", size: .lg, color: .secondary)
                }

                // KbdHint
                fieldRow("KbdHint") {
                    HVMUI.KbdHint("⌘+S")
                    HVMUI.KbdHint(keys: [.cmd, .shift], char: "P")
                    HVMUI.KbdHint(keys: [.cmd, .opt], char: "I", size: .sm)
                    HVMUI.KbdHint(keys: [.enter], size: .md)
                    HVMUI.KbdHint(keys: [.esc], size: .sm)
                }

                // Tooltip demo — hover 按钮 500ms 后出 tooltip
                fieldRow("Tooltip (hover 500ms 后出)") {
                    HVMUI.Button(icon: "trash", variant: .ghost,
                                 probeID: "showcase.tooltip.button.delete") { }
                        .hvmTooltip("删除当前 VM", kbd: "⌫")

                    HVMUI.Button(icon: "plus", variant: .ghost,
                                 probeID: "showcase.tooltip.button.create") { }
                        .hvmTooltip("创建新 VM", edge: .bottom, kbd: "⌘+N")

                    HVMUI.Button("保存", variant: .primary,
                                 probeID: "showcase.tooltip.button.save") { }
                        .hvmTooltip("保存当前修改", kbd: "⌘+S")

                    HVMUI.Icon("info.circle", color: .info)
                        .hvmTooltip("VM 配置说明: 至少 2GB 内存 + 1 CPU 核心", edge: .trailing)
                }
            }
        }
    }

    // PR-C5 — HVMUI.Section / Divider / Badge
    private var sectionsBlock: some View {
        sectionCard(title: "Section / Divider / Badge (PR-C5)",
                    description: "业务页骨架基石: Section (default/elevated + layered shadow + double border), Divider (h/v), Badge (6 variant × 2 size)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                // Section variants (default / elevated)
                fieldRow("Section variants") {
                    HVMUI.Section("默认卡片", description: "default — bgRaised + 轻 shadow") {
                        Text("section content goes here")
                            .font(HVMTheme.font.base)
                            .foregroundStyle(HVMTheme.color.textPrimary)
                    }
                    .frame(maxWidth: 280)

                    HVMUI.Section("Elevated", description: "elevated — bgOverlay + 重 shadow", variant: .elevated) {
                        Text("Dialog / popover 卡片风")
                            .font(HVMTheme.font.base)
                            .foregroundStyle(HVMTheme.color.textPrimary)
                    }
                    .frame(maxWidth: 280)
                }

                // Section with footer
                HVMUI.Section("Section with footer", description: "footer 区会自动加 Divider 跟 content 隔开") {
                    VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                        Text("⌘ 主操作放 footer 右侧")
                            .font(HVMTheme.font.base)
                            .foregroundStyle(HVMTheme.color.textPrimary)
                        Text("⌘ 次要操作放 footer 左侧, 取消放最左")
                            .font(HVMTheme.font.base)
                            .foregroundStyle(HVMTheme.color.textPrimary)
                    }
                } footer: {
                    HStack(spacing: HVMTheme.space.sm) {
                        HVMUI.Button("取消", variant: .secondary,
                                     probeID: "showcase.section.footer.cancel") { }
                        Spacer()
                        HVMUI.Button("丢弃", variant: .ghost,
                                     probeID: "showcase.section.footer.discard") { }
                        HVMUI.Button("保存", variant: .primary,
                                     probeID: "showcase.section.footer.save") { }
                    }
                }

                // Dividers
                fieldRow("Dividers") {
                    VStack(spacing: 0) {
                        Text("上方内容")
                            .font(HVMTheme.font.sm)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                        HVMUI.Divider()
                        Text("下方内容")
                            .font(HVMTheme.font.sm)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                    }
                    .padding(HVMTheme.space.md)
                    .background(HVMTheme.color.bgRaised)
                    .frame(width: 180)

                    HStack(spacing: 0) {
                        Text("左")
                            .font(HVMTheme.font.sm)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                        HVMUI.Divider(.vertical, padding: .md)
                        Text("中")
                            .font(HVMTheme.font.sm)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                        HVMUI.Divider(.vertical, padding: .md)
                        Text("右")
                            .font(HVMTheme.font.sm)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                    }
                    .padding(HVMTheme.space.md)
                    .background(HVMTheme.color.bgRaised)
                    .frame(height: 56)
                }

                // Badges
                fieldRow("Badge variants") {
                    HVMUI.Badge("Running", variant: .success, icon: "circle.fill")
                    HVMUI.Badge("Warning", variant: .warn, icon: "exclamationmark.triangle")
                    HVMUI.Badge("Error", variant: .error, icon: "xmark.circle.fill")
                    HVMUI.Badge("Info", variant: .info, icon: "info.circle")
                    HVMUI.Badge("Recommended", variant: .accent)
                    HVMUI.Badge("Linux", variant: .neutral)
                }

                fieldRow("Badge sizes + numbers") {
                    HVMUI.Badge("PR-C5", variant: .accent, size: .sm)
                    HVMUI.Badge("PR-C5", variant: .accent, size: .md)
                    HVMUI.Badge("3", variant: .error, size: .sm)
                    HVMUI.Badge("12", variant: .info, size: .md)
                    HVMUI.Badge("Encrypted", variant: .accent, icon: "lock.fill", size: .sm)
                }
            }
        }
    }

    // PR-C1b — 5 variant + 3 size + focus ring + loading + iconPosition + probe
    @State private var simulateButtonLoading: Bool = false

    private var buttonsBlock: some View {
        sectionCard(title: "Buttons (PR-C1b)",
                    description: "5 variant × 3 size + focus ring + loading + iconPosition + opacity 降透保 variant 身份感") {
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

                buttonRow("Sizes (.sm / .md / .lg)") {
                    HVMUI.Button("保存", variant: .primary, size: .sm,
                                 probeID: "showcase.button.save.sm") { }
                    HVMUI.Button("保存", variant: .primary, size: .md,
                                 probeID: "showcase.button.save.md") { }
                    HVMUI.Button("保存", variant: .primary, size: .lg,
                                 probeID: "showcase.button.save.lg") { }
                    HVMUI.Button(icon: "gear", variant: .ghost, size: .sm,
                                 probeID: "showcase.button.gear.sm") { }
                    HVMUI.Button(icon: "gear", variant: .ghost, size: .md,
                                 probeID: "showcase.button.gear.md") { }
                    HVMUI.Button(icon: "gear", variant: .ghost, size: .lg,
                                 probeID: "showcase.button.gear.lg") { }
                }

                buttonRow("Icon position") {
                    HVMUI.Button("装机", variant: .primary, icon: "plus",
                                 iconPosition: .leading,
                                 probeID: "showcase.button.install.leading") { }
                    HVMUI.Button("继续", variant: .primary, icon: "arrow.right",
                                 iconPosition: .trailing,
                                 probeID: "showcase.button.continue.trailing") { }
                    HVMUI.Button("删除", variant: .destructive, icon: "trash",
                                 probeID: "showcase.button.delete") { }
                    HVMUI.Button("Settings", variant: .ghost, icon: "gearshape",
                                 probeID: "showcase.button.settings") { }
                }

                buttonRow("Loading") {
                    HVMUI.Button("提交中", variant: .primary, isLoading: true,
                                 probeID: "showcase.button.submitting") { }
                    HVMUI.Button("装机中", variant: .primary, icon: "plus",
                                 isLoading: simulateButtonLoading,
                                 probeID: "showcase.button.loadingDemo") {
                        simulateButtonLoading.toggle()
                    }
                    HVMUI.Button(icon: "gear", variant: .icon, isLoading: true,
                                 probeID: "showcase.button.icon.loading") { }
                }

                buttonRow("Disabled") {
                    HVMUI.Button("Primary", variant: .primary, disabled: true,
                                 probeID: "showcase.button.primary.disabled") { }
                    HVMUI.Button("Secondary", variant: .secondary, disabled: true,
                                 probeID: "showcase.button.secondary.disabled") { }
                    HVMUI.Button("Destructive", variant: .destructive, disabled: true,
                                 probeID: "showcase.button.destructive.disabled") { }
                    HVMUI.Button(icon: "gear", variant: .icon, disabled: true,
                                 probeID: "showcase.button.icon.disabled") { }
                }

                HStack(spacing: HVMTheme.space.sm) {
                    Text("hvm-dbg gui click --identifier showcase.button.loadingDemo")
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
    /// Showcase 节包装 — 改用 HVMUI.Section (C8 整理: Showcase 自己也用新组件,
    /// 不再有独立 helper). 接受 title + 可选 description 副文案.
    private func sectionCard<Content: View>(
        title: String,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HVMUI.Section(title, description: description) {
            content()
        }
    }
}

/// 简单 dialog 卡片 — D1 demo 用. D3 AlertDialog 落地后业务侧改用 dialog.alert(...)
private struct SimpleDialogCard: View {
    let handle: HVMUI.DialogHandle
    let title: String
    let message: String
    var extraLabel: String? = nil
    var extraProbeID: String? = nil
    var extraAction: (@MainActor @Sendable () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack {
                Text(title)
                    .font(HVMTheme.font.lg)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                Spacer()
                HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                             probeID: "demo.dialog.close.x") {
                    handle.close()
                }
            }

            Text(message)
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Button("取消", variant: .secondary,
                             probeID: "demo.dialog.cancel") { handle.close() }
                Spacer()
                if let extraLabel, let extraProbeID, let extraAction {
                    HVMUI.Button(extraLabel, variant: .secondary,
                                 probeID: extraProbeID, action: extraAction)
                }
                HVMUI.Button("确定", variant: .primary,
                             probeID: "demo.dialog.confirm") { handle.close() }
            }
            .padding(.top, HVMTheme.space.xs)
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                .fill(HVMTheme.color.bgOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                        .stroke(HVMTheme.color.borderEmphasis,
                                lineWidth: HVMTheme.border.hairline)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
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
