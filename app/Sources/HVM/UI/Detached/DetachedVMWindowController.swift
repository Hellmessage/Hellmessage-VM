// DetachedVMWindowController.swift
//
// QEMU 后端 VM 的"独立窗体"窗口. 跟主窗口的嵌入路径**共存**:
//   - 同一 fanout session, 同一 VM 同一份 IOSurface
//   - 主窗口右栏的 FramebufferHostView 仍持续渲染
//   - 独立窗口里的 FramebufferHostView 是另一个 fanout subscriber, 跟主窗口
//     同步显示; resize 由独立窗口的 windowDidEndLiveResize 触发 (主嵌入只
//     letterbox 显示)
//   - 输入: 各 view 自带 InputForwarder, key window 那个 view 拿到 NSEvent,
//     自动只有一边发输入到 guest
//
// 风格: fullSizeContentView + 透明标题栏 + 顶部一条 toolbar
// (traffic light + GuestBadge + 名字 + 状态 + 配置 + 控制按钮 Pause/Stop/Kill +
// clipboard toggle + close detached). **底部无 chrome**, framebuffer 直接顶到底,
// 跟 Parallels / VMware Fusion 风格一致.

import AppKit
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplayQemu

@MainActor
final class DetachedVMWindowController: NSWindowController, NSWindowDelegate {

    private let model: AppModel
    private let vmID: UUID
    private let fanout: QemuFanoutSession
    /// 这个独立窗口里的 framebuffer view. fanout subscriber, 不当 resize master.
    private var fbView: FramebufferHostView?
    private var toolbarHost: NSHostingView<DetachedVMToolbar>?
    private var observationTask: Task<Void, Never>?

    /// 默认窗口尺寸 / 最小尺寸. 独立窗口主要用来在副屏全屏看 guest, 给个 1024x768
    /// 起步, 用户可拖大或全屏切.
    private static let defaultSize = NSSize(width: 1024, height: 768)
    private static let minSize     = NSSize(width: 640,  height: 480)

    init(model: AppModel, item: AppModel.VMListItem, fanout: QemuFanoutSession) {
        self.model = model
        self.vmID = item.id
        self.fanout = fanout

        // **borderless** window 彻底去掉系统 titlebar — 之前 .titled +
        // fullSizeContentView 仍保留 NSWindow 的 titlebar layout 概念 (28px
        // 拖动区), 跟我们自家 toolbar 重叠出 layout 异常. borderless 整 window
        // 都是 content view, 自家全管 (toolbar / 拖动 / 红绿灯).
        let style: NSWindow.StyleMask = [.borderless, .resizable, .miniaturizable]
        let window = BorderlessKeyableWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = item.displayName  // 给 cmd+tab / Mission Control 显示
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        // borderless 默认无圆角, 自家给 contentView 加 cornerRadius.
        // 黑底跟嵌入路径视觉一致 (CLAUDE.md: 主窗口不跟随系统主题, 走深色)
        window.backgroundColor = NSColor.black
        window.appearance = NSAppearance(named: .darkAqua)
        // borderless 拖动: isMovableByWindowBackground=true 让 background NSView
        // (即 toolbar 区, 因为 toolbar 是 SwiftUI HStack 的 background 不接 mouseDown)
        // 触发 window 拖. FramebufferHostView 自己 override mouseDown 给 InputForwarder,
        // 不会 propagate 到 window, 所以拖 framebuffer 不会拖窗口. ✓
        window.isMovable = true
        window.isMovableByWindowBackground = true
        // 整 contentView 圆角 (跟标准 macOS 窗口视觉一致)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10
        window.contentView?.layer?.masksToBounds = true

        super.init(window: window)
        window.delegate = self
        installContentView(item: item)
        // 按 guest 当前分辨率定窗口 contentArea: guest pixel 直接当 points,
        // 加 toolbar 实测高度. clamp 到 visibleFrame*0.9 防超屏. 没拿到 guest size
        // (fanout 还没收首帧) → 用 defaultSize.
        applyInitialContentSize()
        observeItemUpdates()
    }

    /// chrome 高度初始估算 (toolbar 一条, 跟 macOS titlebar 一致 28 + 1 divider).
    /// 真实值由 layout pass 后量出, 这里只是首次 setContentSize 用的近似.
    private static let chromeHeightEstimate: CGFloat = 29

    private func applyInitialContentSize() {
        guard let window = self.window else { return }
        let guestSize = fanout.currentGuestPixelSize ?? CGSize(
            width: Self.defaultSize.width,
            height: Self.defaultSize.height
        )
        let guestRatio = guestSize.width / guestSize.height

        // pass 1: 用估算 chrome 设 contentSize, 给 layout 一个起点.
        var contentSize = NSSize(width: guestSize.width,
                                  height: guestSize.height + Self.chromeHeightEstimate)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            contentSize.width  = min(contentSize.width,  visible.width  * 0.9)
            contentSize.height = min(contentSize.height, visible.height * 0.9)
        }
        contentSize.width  = max(Self.minSize.width,  contentSize.width)
        contentSize.height = max(Self.minSize.height, contentSize.height)
        window.setContentSize(contentSize)

        // pass 2: layout 后量真实 toolbar 高度, 反算 fbView 高度让其严格保持 guest
        // 比例 — 否则 fbView 比例偏离 guest, FramebufferRenderer 等比 letterbox
        // 出大左右黑边.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  let toolbar = self.toolbarHost else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            let actualChrome = toolbar.frame.height
            let curContent = window.contentLayoutRect.size
            let desiredFbH = curContent.width / guestRatio
            var newSize = NSSize(width: curContent.width,
                                  height: desiredFbH + actualChrome)
            // 重 clamp 到屏幕可用范围, 撞顶反推另一边保 ratio
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                if newSize.height > visible.height * 0.9 {
                    newSize.height = visible.height * 0.9
                    newSize.width = (newSize.height - actualChrome) * guestRatio
                }
                if newSize.width > visible.width * 0.9 {
                    newSize.width = visible.width * 0.9
                    newSize.height = newSize.width / guestRatio + actualChrome
                }
            }
            newSize.width  = max(Self.minSize.width,  newSize.width)
            newSize.height = max(Self.minSize.height, newSize.height)
            if abs(newSize.height - curContent.height) > 4 || abs(newSize.width - curContent.width) > 4 {
                window.setContentSize(newSize)
            }
            window.center()
            // 同步设 contentAspectRatio 让用户拖动也保持 ratio
            window.contentAspectRatio = NSSize(
                width: newSize.width,
                height: newSize.height
            )
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observationTask?.cancel()
    }

    /// AppModel.closeDetachedQemuWindow 调用; 触发后窗口先 unsubscribe + close.
    /// windowWillClose delegate 不再回调 AppModel (避免双重 closeDetached).
    func tearDown() {
        observationTask?.cancel(); observationTask = nil
        if let v = fbView {
            fanout.removeSubscriber(v)
            v.removeFromSuperview()
        }
        fbView = nil
        toolbarHost = nil
        // 切断 delegate 防止 close → windowWillClose → AppModel 二次 closeDetached
        window?.delegate = nil
        window?.close()
    }

    // MARK: - 内容布局: toolbar (一条, fullSizeContentView 内) + framebuffer (占余)

    private func installContentView(item: AppModel.VMListItem) {
        guard let window = self.window else { return }
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.translatesAutoresizingMaskIntoConstraints = false

        // sharedErrors 在 HVMAppDelegate 启动时注入; 兜底用一个 detached 自己的
        // ErrorPresenter (报错只会写自己的 queue, DialogOverlay 看不到 — 但保证不崩).
        let errors = model.sharedErrors ?? ErrorPresenter()
        let toolbar = NSHostingView(rootView: DetachedVMToolbar(
            model: model, errors: errors, item: item
        ))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setContentHuggingPriority(.required, for: .vertical)
        toolbar.setContentCompressionResistancePriority(.required, for: .vertical)
        // 强制 28 px 高度 (跟 macOS 标准 titlebar 一致). NSHostingView 的 intrinsicContentSize
        // 会取 SwiftUI fitting size, 内容可能因 IconButtonStyle 等子项 padding 变高 —
        // 显式 height constraint 确保 toolbar 严格 28, 红绿灯 vertical center 落在 14 px
        // 跟 macOS traffic light 标准位置一致.
        toolbar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        self.toolbarHost = toolbar

        let fb = FramebufferHostView(frame: .zero)
        fb.macStyleShortcuts = item.config.macStyleShortcuts
        fb.translatesAutoresizingMaskIntoConstraints = false
        fb.setContentHuggingPriority(.defaultLow, for: .vertical)
        fb.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        self.fbView = fb

        let toolbarDivider = makeDivider()

        root.addSubview(toolbar)
        root.addSubview(toolbarDivider)
        root.addSubview(fb)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            toolbarDivider.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1),

            fb.topAnchor.constraint(equalTo: toolbarDivider.bottomAnchor),
            fb.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            fb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fb.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        window.contentView = root

        // 注册成 fanout subscriber + resize master: 拖独立窗口尺寸变化时推 RESIZE_REQUEST
        // 给 guest 改分辨率 (主窗口嵌入 view 故意不当 master, 它走 letterbox 显示原始尺寸).
        fanout.addSubscriber(fb, isResizeMaster: true)
    }

    private func makeDivider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return v
    }

    // MARK: - 监听 item 变化 (displayName 改 → 窗口 title 跟着改)

    private func observeItemUpdates() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            // 简化: 1Hz 轮询 list 里的 displayName 变化即可, 改名是低频操作
            while let self, !Task.isCancelled {
                if let item = self.model.list.first(where: { $0.id == self.vmID }),
                   self.window?.title != item.displayName {
                    self.window?.title = item.displayName
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 用户点 X / cmd+W 关窗 → 通知 AppModel 清状态. AppModel 会回调 tearDown,
        // 但 tearDown 里已切断 delegate, 此回调不会再次进入.
        model.closeDetachedQemuWindow(id: vmID)
    }

    /// 仅在用户**真正拖动**窗口边角结束时触发 (NSWindow live resize). 程序化
    /// setContentSize / autolayout 不调这个回调. 这是 macOS 区分"用户拖动" vs
    /// "代码 resize" 的标准 API. 只在这里调 fanout 改 guest 分辨率, 避免开窗 /
    /// 切换 view 时因 layout 微调误触发 resize.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let fb = fbView else { return }
        let dsize = fb.drawableSize
        guard dsize.width >= 1, dsize.height >= 1 else { return }
        let w = UInt32(dsize.width.rounded())
        let h = UInt32(dsize.height.rounded())
        fanout.requestResizeFromUser(width: w, height: h)
    }
}

// MARK: - DetachedVMToolbar

/// 独立窗口顶部一条 toolbar. 整合原来 DetailTopBar (GuestBadge + 名字 + 状态 +
/// clipboard toggle + detach toggle) + DetailBottomBar (config text + Pause/Stop/Kill)
/// 为单层, 释放底部空间.
///
/// 布局: [80px traffic light 让位] [GuestBadge + name + status] [spacer]
///       [config text small] [Pause/Resume] [Stop] [Kill] [clipboard] [close detached]
private struct DetachedVMToolbar: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    private var sessionState: RunState {
        if let s = model.sessions[item.id]?.state { return s }
        return item.runState == "running" ? .running : .stopped
    }

    /// 实时查 model.list 拿当前 config — clipboard toggle 等 in-place 改动后, item
    /// 这个 let snapshot 不会更新, 必须读 model 才能触发 SwiftUI 重 render.
    private var liveConfig: VMConfig {
        model.list.first(where: { $0.id == item.id })?.config ?? item.config
    }

    /// 跟 macOS 标准 titlebar 高度一致 — traffic light 直径 12, center y ≈ 14;
    /// 让 toolbar 内容 vertical center 也落在 ~14, 视觉上跟 traffic light 同行.
    private static let toolbarHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: HVMSpace.sm) {
            // 自家画三个红绿灯按钮, 视觉跟 macOS 系统 traffic light 一致.
            // close=红: 关 detached 窗口 (不停 VM, 仅收回独立显示)
            // min=黄: NSWindow.miniaturize
            // zoom=绿: NSWindow.zoom (full screen toggle)
            TrafficLights(
                onClose:    { model.toggleDetachedQemu(id: item.id) },
                onMinimize: { NSApp.keyWindow?.miniaturize(nil) },
                onZoom:     { NSApp.keyWindow?.toggleFullScreen(nil) }
            )

            GuestBadge(os: item.guestOS, size: 16)

            // 名字 + 状态 横排 (不再 VStack 占两行垂直, 把高度压在 28 内)
            Text(item.displayName)
                .font(HVMFont.body.weight(.semibold))
                .foregroundStyle(HVMColor.textPrimary)
                .lineLimit(1)
            StatusBadge(state: sessionState)

            Spacer(minLength: HVMSpace.md)

            Text("\(item.config.cpuCount) cores · \(item.config.memoryMiB / 1024) GB · \(networkMode(item.config))")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
                .lineLimit(1)

            Spacer(minLength: HVMSpace.sm)

            // ---- 控制按钮 (icon-only, IconButtonStyle 提供 hover/press 反馈) ----

            // Pause / Resume
            if case .paused = sessionState {
                Button {
                    Task { do { try await model.resume(item.id) } catch { errors.present(error) } }
                } label: { Image(systemName: "play.fill") }
                    .buttonStyle(IconButtonStyle())
                    .help("继续")
            } else {
                Button {
                    Task { do { try await model.pause(item.id) } catch { errors.present(error) } }
                } label: { Image(systemName: "pause.fill") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(sessionState != .running)
                    .help("暂停")
            }

            // Stop (ACPI)
            Button {
                do { try model.stop(item.id) } catch { errors.present(error) }
            } label: { Image(systemName: "stop.fill") }
                .buttonStyle(IconButtonStyle())
                .help("停止 (软关机)")

            // Kill (force)
            Button {
                Task { do { try await model.kill(item.id) } catch { errors.present(error) } }
            } label: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(HVMColor.statusError)
            }
                .buttonStyle(IconButtonStyle())
                .help("强制结束")

            // 剪贴板共享 toggle (仅 QEMU 后端有意义). 跟其他按钮同灰色风格, 仅靠图标
            // 填充态 (.fill) 区分开/关, 不再用蓝色 accent 在黑底上抢眼.
            // **读 liveConfig 不读 item.config**: toggle 后 model.list 更新, view 重 render
            // 才能切图标 (item 是 init 时 captured 的 immutable snapshot).
            if item.config.engine == .qemu {
                let on = liveConfig.clipboardSharingEnabled
                Button {
                    do {
                        try model.toggleClipboardSharing(item: item, enabled: !on)
                    } catch {
                        errors.present(error)
                    }
                } label: {
                    Image(systemName: on ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                        .foregroundStyle(on ? HVMColor.textPrimary : HVMColor.textSecondary)
                }
                    .buttonStyle(IconButtonStyle())
                    .help(on ? "剪贴板共享: 开 (点击关闭)" : "剪贴板共享: 关 (点击开启)")
            }

        }
        .padding(.leading, HVMSpace.md)
        .padding(.trailing, HVMSpace.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(HVMColor.bgSidebar)
    }

    private func networkMode(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "—" }
        switch net.mode {
        case .user:         return "NAT"
        case .vmnetShared:  return "vmnet shared"
        case .vmnetHost:    return "vmnet host"
        case .vmnetBridged: return "vmnet bridged"
        case .none:         return "无网络"
        }
    }
}

// MARK: - BorderlessKeyableWindow

/// borderless NSWindow 默认不能成为 key window (canBecomeKey/Main 默认 false),
/// 表现为窗口看起来"灰着不 active", 键盘事件不送 first responder. 必须 subclass
/// override.
final class BorderlessKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - TrafficLights

/// 自家画 macOS 风红绿灯三按钮 (close=红 / minimize=黄 / zoom=绿).
/// 视觉跟系统 traffic light 一致 (12px 圆 + 灰边 + hover 时显示 icon: ✕ / − / +).
/// 行为由调用方注入 closure (close 通常关 detached 而非整 window, 跟系统语义有别).
/// hover 检测: 用 group hover (整 HStack) — macOS 系统行为也是这样, 鼠标进入任一灯
/// 三个灯都同时显示 icon, 不是 per-button.
private struct TrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(color: Color(red: 1.0, green: 0.37, blue: 0.36),  symbol: "xmark", action: onClose)
            light(color: Color(red: 1.0, green: 0.74, blue: 0.18),  symbol: "minus", action: onMinimize)
            light(color: Color(red: 0.16, green: 0.79, blue: 0.27), symbol: "plus",  action: onZoom)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func light(color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                    )
                if isHovering {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

