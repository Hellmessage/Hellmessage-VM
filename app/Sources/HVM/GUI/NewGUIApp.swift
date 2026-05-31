// NewGUIApp.swift — 新 GUI 主入口 (AppKit runloop + tray + 菜单) + 组件 Showcase 演示页.
//
// 默认走业务页 MainLayoutView; HVM_GUI_SHOWCASE=1 退回 NewGUIRootView 组件 Showcase (living doc / 视觉回归).


import AppKit
import SwiftUI
import HVMGuiProbe
import HVMCore
import HVMControl

@MainActor
final class NewGUIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    // 状态栏 tray 图标 (强引用保活, nil 时 AppKit 立即回收 statusItem).
    private var statusItem: NSStatusItem?
    // 用户从 tray 菜单"退出 HVM"主动退出 → 放行真退出; 否则 Cmd+Q / 点 X 只隐藏到 tray.
    private var userRequestedQuit = false
    // GUI 在世标记锁: VMHost 探到此锁被占即撤自己的 tray, 由 GUI 统一管 (见 TrayCoordinator).
    private var guiOwnerLock: ProcessFileLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)

        // GUI 单例化: 抢 gui-owner.lock. 抢不到 = 已有 GUI 在世 → 让它前置窗口, 本实例自退.
        // (VMHost 也是 HVM.app 实例, "打开主界面" 走 createsNewApplicationInstance 起新进程, 单例靠此收口.)
        guard let lock = ProcessFileLock(path: HVMPaths.guiOwnerLockPath) else {
            DistributedNotificationCenter.default().postNotificationName(
                TrayCoordinator.nGuiShowWindow, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        guiOwnerLock = lock
        // 广播 gui.up → 各 VMHost 即时撤自己的 tray, 由 GUI 接管.
        DistributedNotificationCenter.default().postNotificationName(
            TrayCoordinator.nGuiUp, object: nil, userInfo: nil, deliverImmediately: true)
        // 监听第二个 GUI 实例的"显示窗口"请求 (单例前置).
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onShowWindowSignal),
            name: TrayCoordinator.nGuiShowWindow, object: nil)

        // 锁定最小尺寸三件套 (单写 win.minSize 不够): root view .frame(min) + host.sizingOptions = .minSize
        // + win.contentMinSize. 不用 win.minSize (含 28px 标题栏, content 仍能被压).
        // .hvmDialogHost() 套在 root view 外层作祖先, 让内部 @EnvironmentObject 拿到 DialogPresenter.
        let showcase = ProcessInfo.processInfo.environment["HVM_GUI_SHOWCASE"] == "1"
        let rootView: AnyView = showcase
            ? AnyView(NewGUIRootView())
            : AnyView(MainLayoutView())
        let host = NSHostingController(rootView: rootView.hvmDialogHost())
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
        // 拦截红色 X: windowShouldClose 隐藏到 tray 而非关闭/退出.
        win.delegate = self
        self.window = win

        // 状态栏 tray 图标 — 隐藏窗口后 app 进 .accessory (Dock 图标消失), tray 是唯一恢复/退出入口.
        installStatusItem()

        // 菜单栏 — 纯 AppKit 必须显式设 mainMenu, 否则 Cmd+Q / 输入框 Cmd+C/V/X/A/Z 全失效
        installMainMenu()

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 清掉 AppKit 默认把首个文本框设为 firstResponder 的自动聚焦 (async 到下一 runloop)
        DispatchQueue.main.async { [weak win] in win?.makeFirstResponder(nil) }

        // HDP-GUI probe server (HVM_GUI_PROBE=1 时 unix socket 接 hvm-dbg gui)
        ProbeServer.start()
    }

    // 窗口不真关 (隐藏到 tray), 此回调实际不触发; 保守返 false 防"无窗口即退出".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - tray 隐藏 / 退出闭环

    /// Cmd+Q (以及菜单"退出 HVM" / NSApp.terminate) 统一走这里:
    /// 仅 tray 菜单主动退出时放行真退出, 否则隐藏到 tray.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userRequestedQuit { return .terminateNow }
        hideToTray()
        return .terminateCancel
    }

    /// 真退出前: 广播 gui.down + 放 gui-owner.lock → 仍在跑的 VMHost 即时选主, 把 tray 接回去 (回退 tray 模式).
    /// 默认退出不停 VM (D3); "停止所有并退出" 由专门菜单项负责.
    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().postNotificationName(
            TrayCoordinator.nGuiDown, object: nil, userInfo: nil, deliverImmediately: true)
        guiOwnerLock?.release()
        guiOwnerLock = nil
    }

    /// 点 Dock 图标 / Finder 重新打开 → 恢复主窗口 (accessory 态无 Dock 图标, 兜底仍保留).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 点红色 X → 隐藏到 tray, 不真关窗口.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideToTray()
        return false
    }

    /// 隐藏主窗口并切 .accessory (Dock 图标消失, 纯后台只剩 tray 图标).
    private func hideToTray() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// 从 tray / Dock 恢复: 切回 .regular + 前置激活主窗口.
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 装状态栏 tray 图标 + 菜单 ("显示 HVM 主窗口" / "退出 HVM").
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "shippingbox.fill",
                                 accessibilityDescription: "HVM") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "HVM"
            }
        }
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示 HVM 主窗口",
                              action: #selector(showWindowAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        // 默认退出: 只关 GUI, VM 后台继续 (tray 回退给 VMHost).
        let quit = NSMenuItem(title: "退出 HVM (VM 后台继续)",
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        // 显式全停: 停掉所有运行中 VM 再退.
        let quitAll = NSMenuItem(title: "停止所有 VM 并退出",
                                 action: #selector(quitAndStopAllAction), keyEquivalent: "")
        quitAll.target = self
        menu.addItem(quitAll)
        item.menu = menu
        self.statusItem = item
    }

    /// 装标准菜单栏. App 菜单「退出 HVM」走 terminate: → applicationShouldTerminate 拦截隐藏;
    /// Edit 菜单提供文本框标准编辑快捷键 (无 mainMenu 时这些 key equivalent 全失效).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单 (第一个 submenu, 系统自动用 app 名作标题)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 HVM",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 HVM",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // 退出: terminate: → applicationShouldTerminate → hideToTray (不真退出)
        appMenu.addItem(withTitle: "退出 HVM",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit 菜单 — 文本框 Cmd+C/V/X/A/Z 依赖此菜单的 key equivalents
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showWindowAction() {
        showMainWindow()
    }

    /// 第二个 GUI 实例请求前置 (单例): 本在世 GUI 恢复主窗口.
    @objc private func onShowWindowSignal() {
        showMainWindow()
    }

    @objc private func quitAction() {
        userRequestedQuit = true
        NSApp.terminate(nil)
    }

    /// 停止所有运行中 VM (ACPI) 再退出. VMHost 全停后无人接 tray, 干净退出.
    @objc private func quitAndStopAllAction() {
        let running = VMCatalog.list().filter { $0.runState == .running }
        DispatchQueue.global(qos: .userInitiated).async {
            for vm in running { try? VMControl.stop(bundleURL: vm.bundleURL) }
            DispatchQueue.main.async {
                self.userRequestedQuit = true
                NSApp.terminate(nil)
            }
        }
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
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    @State private var probeClickLog: String = "—"

    var body: some View {
        ZStack(alignment: .topLeading) {
            HVMTheme.color.bgBase
                .ignoresSafeArea()

            ScrollView {
                // 反向 zIndex (上→下递减) 让上面 sectionCard 内的 Select popover 浮在下方之上.
                // 节顺序: header → 交互组件 → 装饰类 → Theme token 参考.
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

    enum DemoEngine: Hashable { case vz, qemu }
    @State private var engineSelection: DemoEngine? = .vz
    @State private var isoSelection: String? = nil
    @State private var cpuSelection: Int = 4

    private var selectsBlock: some View {
        sectionCard(title: "Select (PR-C4)",
                    description: "自绘下拉, 不用 SwiftUI .popover. generic value + 搜索 + 键盘 ↑↓Enter + 互斥打开 + 派生 probe id") {
            // 反向 zIndex 让上面 Select popover 浮在下方 fieldRow 之上
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

    @State private var autoStart: Bool = true
    @State private var networkOn: Bool = false
    @State private var hostKeyboard: Bool = true
    @State private var hostMouse: Bool = false
    @State private var termsAccepted: Bool = false
    @State private var filterRunning: Bool = true
    @State private var selectAllPartial: Bool = false

    private var togglesBlock: some View {
        sectionCard(title: "Toggle / Checkbox (PR-C3)",
                    description: "3 档 size + spring 切换 + indeterminate 半选态 + disabled 灰化用 bgDisabled token") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                fieldRow("Toggle Sizes") {
                    HVMUI.Toggle("自动启动", isOn: $autoStart, size: .sm,
                                 probeID: "showcase.toggle.autostart.sm")
                    HVMUI.Toggle("自动启动", isOn: $autoStart,
                                 hint: "登录时自动启 VM", size: .md,
                                 probeID: "showcase.toggle.autostart.md")
                    HVMUI.Toggle("自动启动", isOn: $autoStart, size: .lg,
                                 probeID: "showcase.toggle.autostart.lg")
                }

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

                fieldRow("Checkbox Sizes") {
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .sm,
                                   probeID: "showcase.checkbox.filter.sm")
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .md,
                                   probeID: "showcase.checkbox.filter.md")
                    HVMUI.Checkbox("仅显示运行中", isOn: $filterRunning, size: .lg,
                                   probeID: "showcase.checkbox.filter.lg")
                }

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

    @State private var vmName: String = ""
    @State private var cpuCount: String = "4"
    @State private var ipsw: String = ""
    @State private var password: String = ""
    @State private var simulateLoading: Bool = false

    private var fieldsBlock: some View {
        sectionCard(title: "TextField / SecureField (PR-C2)",
                    description: "3 档 size + 7 状态 (empty/filled/focused/hover/error/loading/disabled) + focus ring 渐现 + 共享 FieldChrome modifier") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
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

                fieldRow("SecureField") {
                    HVMUI.SecureField("密码", text: $password,
                                   placeholder: "至少 8 字符",
                                   showToggle: true,
                                   errorMessage: password.count > 0 && password.count < 8
                                       ? "密码至少 8 字符" : nil,
                                   probeID: "showcase.field.password")
                        .frame(maxWidth: 320)
                }

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

    private var dialogDemoBlock: some View {
        sectionCard(title: "OverlayContainer + AlertDialog (PR-D1 / D3)",
                    description: "全局 dialog 渲染容器 — popover 渲染到 root-level ZStack. Alert 4 档 (info/warn/error/success) async API. Confirm/Input/Wizard 后续 D4-D6") {
            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                fieldRow("Custom dialog (PR-D1)") {
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

                fieldRow("AlertDialog (PR-D3, async API)") {
                    HVMUI.Button("Info", variant: .secondary, icon: "info.circle",
                                 probeID: "showcase.alert.info") {
                        Task { @MainActor in
                            await dialog.alert(
                                level: .info,
                                title: "提示",
                                message: "这是一个 info 级别的 alert dialog. async API 等用户关闭后才 resume.",
                                hint: "可以传 hint 副文案",
                                probeID: "showcase.alert.info.dlg"
                            )
                        }
                    }
                    HVMUI.Button("Warn", variant: .secondary, icon: "exclamationmark.triangle",
                                 probeID: "showcase.alert.warn") {
                        Task { @MainActor in
                            await dialog.alert(
                                level: .warn,
                                title: "警告",
                                message: "存在潜在问题但操作可以继续.",
                                hint: "例: vmnet daemon 配置缺失但 VM 仍可启动",
                                probeID: "showcase.alert.warn.dlg"
                            )
                        }
                    }
                    HVMUI.Button("Error", variant: .destructive, icon: "xmark.circle",
                                 probeID: "showcase.alert.error") {
                        Task { @MainActor in
                            await dialog.alert(
                                level: .error,
                                title: "启动失败",
                                message: "无法连接到 vmnet daemon.",
                                hint: "检查 socket_vmnet 是否已安装 (brew install socket_vmnet)",
                                probeID: "showcase.alert.error.dlg"
                            )
                        }
                    }
                    HVMUI.Button("Success", variant: .secondary, icon: "checkmark.circle",
                                 probeID: "showcase.alert.success") {
                        Task { @MainActor in
                            await dialog.alert(
                                level: .success,
                                title: "完成",
                                message: "VM 已成功导入并启动.",
                                probeID: "showcase.alert.success.dlg"
                            )
                        }
                    }
                }

                fieldRow("ConfirmDialog (PR-D4, async API)") {
                    HVMUI.Button("普通确认", variant: .secondary,
                                 probeID: "showcase.confirm.normal") {
                        Task { @MainActor in
                            let r = await dialog.confirm(
                                title: "保存修改?",
                                message: "未保存的修改将丢失.",
                                confirmLabel: "保存",
                                probeID: "showcase.confirm.normal.dlg"
                            )
                            probeClickLog = "confirm.normal → \(r)"
                        }
                    }
                    HVMUI.Button("危险操作 (destructive)", variant: .destructive,
                                 icon: "trash",
                                 probeID: "showcase.confirm.destructive") {
                        Task { @MainActor in
                            let r = await dialog.confirm(
                                title: "删除 VM?",
                                message: "VM 'ubuntu-24' 的所有数据将被删除. 此操作不可恢复.",
                                confirmLabel: "删除",
                                destructive: true,
                                probeID: "showcase.confirm.destructive.dlg"
                            )
                            probeClickLog = "confirm.destructive → \(r)"
                        }
                    }
                }

                fieldRow("InputDialog (PR-D5, async API)") {
                    HVMUI.Button("单字段 (重命名)", variant: .secondary, icon: "pencil",
                                 probeID: "showcase.input.rename") {
                        Task { @MainActor in
                            let r = await dialog.input(
                                title: "重命名 VM",
                                fields: [.init(label: "新名称",
                                               placeholder: "ubuntu-24",
                                               initialText: "ubuntu-old")],
                                confirmLabel: "保存",
                                probeID: "showcase.input.rename.dlg"
                            )
                            if case .submitted(let values) = r {
                                probeClickLog = "rename → \(values[0])"
                            } else {
                                probeClickLog = "rename → cancelled"
                            }
                        }
                    }
                    HVMUI.Button("多字段 + validate", variant: .secondary, icon: "folder.badge.plus",
                                 probeID: "showcase.input.shared") {
                        Task { @MainActor in
                            let r = await dialog.input(
                                title: "添加共享目录",
                                fields: [
                                    .init(label: "host 路径",
                                          placeholder: "/Users/me/code",
                                          icon: "folder"),
                                    .init(label: "name", placeholder: "code")
                                ],
                                validate: { values in
                                    if !values[0].hasPrefix("/") {
                                        return .invalid("host 路径必须是绝对路径 (以 / 开头)")
                                    }
                                    if values[1].isEmpty {
                                        return .invalid("name 不能为空")
                                    }
                                    return .valid
                                },
                                confirmLabel: "添加",
                                probeID: "showcase.input.shared.dlg"
                            )
                            if case .submitted(let values) = r {
                                probeClickLog = "shared → \(values[0]) / \(values[1])"
                            } else {
                                probeClickLog = "shared → cancelled"
                            }
                        }
                    }
                    HVMUI.Button("密码 (secure)", variant: .secondary, icon: "lock",
                                 probeID: "showcase.input.password") {
                        Task { @MainActor in
                            let r = await dialog.input(
                                title: "解锁加密 VM",
                                fields: [.init(label: "密码",
                                               placeholder: "请输入密码",
                                               secure: true)],
                                validate: { values in
                                    values[0].count < 4
                                        ? .invalid("密码至少 4 位")
                                        : .valid
                                },
                                confirmLabel: "解锁",
                                probeID: "showcase.input.password.dlg"
                            )
                            if case .submitted = r {
                                probeClickLog = "password → submitted"
                            } else {
                                probeClickLog = "password → cancelled"
                            }
                        }
                    }
                }

                fieldRow("WizardDialog (PR-D6, async API)") {
                    HVMUI.Button("创建 VM 向导 (3 步)",
                                 variant: .primary, icon: "wand.and.stars",
                                 probeID: "showcase.wizard.createVM") {
                        Task { @MainActor in
                            let r = await dialog.wizard(
                                title: "创建 VM",
                                steps: [
                                    .init(title: "选 OS") {
                                        wizardStepDemoOS
                                    },
                                    .init(title: "配置") {
                                        wizardStepDemoConfig
                                    },
                                    .init(title: "确认") {
                                        wizardStepDemoReview
                                    }
                                ],
                                probeID: "showcase.wizard.createVM.dlg"
                            )
                            switch r {
                            case .completed: probeClickLog = "wizard → completed"
                            case .cancelled: probeClickLog = "wizard → cancelled"
                            }
                        }
                    }
                    HVMUI.Button("两步 demo",
                                 variant: .secondary, icon: "checklist",
                                 probeID: "showcase.wizard.twoStep") {
                        Task { @MainActor in
                            let r = await dialog.wizard(
                                title: "两步演示",
                                steps: [
                                    .init(title: "Hello") {
                                        Text("第一步内容 — 任何 SwiftUI View 都可以塞进 step.content")
                                            .font(HVMTheme.font.base)
                                            .foregroundStyle(HVMTheme.color.textSecondary)
                                    },
                                    .init(title: "World") {
                                        Text("第二步内容 — 最后一步「下一步」自动变「完成」")
                                            .font(HVMTheme.font.base)
                                            .foregroundStyle(HVMTheme.color.textSecondary)
                                    }
                                ],
                                probeID: "showcase.wizard.twoStep.dlg"
                            )
                            switch r {
                            case .completed: probeClickLog = "twoStep → completed"
                            case .cancelled: probeClickLog = "twoStep → cancelled"
                            }
                        }
                    }
                }

                Text("hvm-dbg gui click showcase.confirm.* / input.* / wizard.* → 最近: \(probeClickLog)")
                    .font(HVMTheme.font.monoSm)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
        }
    }

    // Wizard 各步 demo 内容 (静态展示, 不持业务态)

    private var wizardStepDemoOS: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text("选择 guest OS").font(HVMTheme.font.md)
                .foregroundStyle(HVMTheme.color.textPrimary)
            Text("演示步骤 — 真实业务页这里放 HVMUI.Select 选 macOS / Linux / Windows.")
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Badge("macOS", variant: .accent)
                HVMUI.Badge("Linux", variant: .info)
                HVMUI.Badge("Windows (实验性)", variant: .warn)
            }
        }
    }

    private var wizardStepDemoConfig: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text("配置硬件").font(HVMTheme.font.md)
                .foregroundStyle(HVMTheme.color.textPrimary)
            Text("演示步骤 — 真实业务页这里放 CPU / 内存 / 磁盘 / 网络 表单.")
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HStack(spacing: HVMTheme.space.md) {
                HVMUI.Badge("4 CPU", variant: .neutral)
                HVMUI.Badge("8 GB", variant: .neutral)
                HVMUI.Badge("64 GB SSD", variant: .neutral)
            }
        }
    }

    private var wizardStepDemoReview: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text("确认创建").font(HVMTheme.font.md)
                .foregroundStyle(HVMTheme.color.textPrimary)
            Text("演示步骤 — 真实业务页这里 review 全部配置, 点「完成」后调 hvm-cli create.")
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HVMUI.Badge("ready to create", variant: .success)
        }
    }

    private var iconsBlock: some View {
        sectionCard(title: "Icon / KbdHint / Tooltip (PR-C6)",
                    description: "辅助组件: Icon 包装 SF Symbol (5 size + 9 color), KbdHint 快捷键 chip (typed Key enum), Tooltip 自绘 hover 500ms delay") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
                fieldRow("Icon sizes (.xs / .sm / .md / .lg / .xl)") {
                    HVMUI.Icon("gear", size: .xs)
                    HVMUI.Icon("gear", size: .sm)
                    HVMUI.Icon("gear", size: .md)
                    HVMUI.Icon("gear", size: .lg)
                    HVMUI.Icon("gear", size: .xl)
                }

                fieldRow("Icon colors") {
                    HVMUI.Icon("checkmark.circle.fill", size: .lg, color: .success)
                    HVMUI.Icon("exclamationmark.triangle.fill", size: .lg, color: .warn)
                    HVMUI.Icon("xmark.circle.fill", size: .lg, color: .error)
                    HVMUI.Icon("info.circle.fill", size: .lg, color: .info)
                    HVMUI.Icon("sparkles", size: .lg, color: .accent)
                    HVMUI.Icon("ellipsis", size: .lg, color: .secondary)
                }

                fieldRow("KbdHint") {
                    HVMUI.KbdHint("⌘+S")
                    HVMUI.KbdHint(keys: [.cmd, .shift], char: "P")
                    HVMUI.KbdHint(keys: [.cmd, .opt], char: "I", size: .sm)
                    HVMUI.KbdHint(keys: [.enter], size: .md)
                    HVMUI.KbdHint(keys: [.esc], size: .sm)
                }

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

    private var sectionsBlock: some View {
        sectionCard(title: "Section / Divider / Badge (PR-C5)",
                    description: "业务页骨架基石: Section (default/elevated + layered shadow + double border), Divider (h/v), Badge (6 variant × 2 size)") {
            VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
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
            Text("HVM 新 GUI")
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
    /// Showcase 节包装 — HVMUI.Section + title + 可选 description.
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

/// 简单 dialog 卡片 — Showcase demo 用 (业务侧改用 dialog.alert(...) 等 async API)
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

/// hover 触发 bg 切换 — 验动效 token 时长.
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

