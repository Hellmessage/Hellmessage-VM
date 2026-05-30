// FramebufferHostView.swift
//
// 主窗口右栏的 QEMU 嵌入视图. 跟 VZ 通路的 HVMView (HVMDisplay 模块) 平行.
//
// 职责:
//   1. 持有 MTKView, 由 FramebufferRenderer 在 draw(in:) 中渲染当前 framebuffer
//   2. 拦截 NSEvent 键鼠 → InputForwarder (走独立 QMP socket)
//   3. CapsLock 同步: 接 DisplayChannel.events 的 LED_STATE, 跟 host
//      modifierFlags.capsLock 比对; host 触发按键前如发现不一致, 强制
//      guest 端 caps_lock toggle 让两边 LED 对齐 (策略参考 hell-vm)
//   4. 鼠标进入隐藏 host cursor (guest 内有自己的硬件光标)
//
// 由上层 (DetailContainerView 在 Phase 3) 创建并 attach DisplayChannel +
// InputForwarder + FramebufferRenderer 三件套.
//
// ---- 键盘捕获双态 (UTM 风格) ----
//
//   released (默认): view 接收键鼠事件, 但 macOS 系统快捷键 (Cmd+Tab / Cmd+Space /
//                    Mission Control / 截图) 仍由 macOS 处理, 不进 guest.
//                    用户常用模式 (操作 host menubar / 切窗口体验正常).
//
//   captured:        Cmd+Opt 切换进入. 通过 CGSSetGlobalHotKeyOperatingMode(.disable)
//                    禁用 macOS 全局热键, 所有键 (包括 cmd+tab) 全部送 guest.
//                    再按 Cmd+Opt 退回 released.
//
// 修饰键卡键防护 (老 bug "shift / cmd 一直按着" 的根治):
//   * lastModifiers — NSEvent.ModifierFlags 镜像, flagsChanged 用 set diff 算
//     新按下 / 新松开. 跟 UTM VMMetalView.lastModifiers 同款做法.
//   * pressedModifierQcodes — 实际已发给 guest keyDown 未发对应 keyUp 的 modifier
//     qcode 集合. resignFirstResponder / viewWillMove(toWindow:nil) / 切 captured
//     模式时全部 keyUp + clear.
//   * pressedNormalKeyQcodes — 同上, 跟踪非修饰键. 老逻辑只清这个不清 modifier,
//     用户 cmd+tab 切走再回来 guest 卡在 cmd down → 此次重构修复.

import Foundation
import AppKit
import MetalKit

public final class FramebufferHostView: MTKView, MTKViewDelegate {

    public let renderer: FramebufferRenderer

    /// 输入转发器, 由 fanout 注入 (weak).
    /// 重要: QEMU `-qmp unix:..,server=on,wait=off` 是**单 client** chardev socket,
    /// 不允许多个客户端并发连接 (第二个 client 会卡在 greeting). 所以同 VM 多 view
    /// 共存时**必须共享同一个 InputForwarder 实例** (fanout 内 own), 不能各自连
    /// 各自 socket. 每次发 input 前 view 自己 setViewSize 同步自己的 size,
    /// NSEvent 一时刻只送一个 view, 串行无竞争.
    public weak var forwarder: InputForwarder?

    /// view drawable 尺寸改变时回调, 通常上层 (QemuFanoutSession 给 resize master
    /// 那个 view 设置) 接到后调 DisplayChannel.requestResize 让 guest 改分辨率.
    /// 参数是 drawable pixel 尺寸 (已乘 backingScaleFactor, 给 guest 的真实分辨率).
    /// 非 resize master 的 view (例如 detached 独立窗口) 应保持 nil, 避免多 view
    /// 之间反复 resize 拉锯 guest 分辨率.
    public var onDrawableSizeChange: ((UInt32, UInt32) -> Void)?

    /// 我们预期 guest CapsLock 当前状态. 每次发 caps_lock toggle 翻转;
    /// 收到 LED_STATE 时用 ground truth 校正. 这是单一 source 避免 LED_STATE
    /// 回传延迟造成的双重 toggle race.
    private var expectedGuestCaps: Bool = false

    /// 上一次 NSEvent.modifierFlags 全量, flagsChanged 用 set diff 算 down/up.
    /// 进/出 captured 模式 + 失焦时 reset 为 [].
    private var lastModifiers: NSEvent.ModifierFlags = []

    /// 已发给 guest keyDown 但还没发 keyUp 的 modifier qcode 集合
    /// (例如 {"shift", "ctrl_r"}). resignFirstResponder / 失焦 / toggle capture
    /// 时一并 keyUp + clear, 防 guest 卡键.
    private var pressedModifierQcodes: Set<String> = []

    /// 已发给 guest keyDown 但还没发 keyUp 的非修饰键 qcode 集合
    /// (例如 {"a", "tab"}). 跟 pressedModifierQcodes 平行管理, 相同时机清理.
    private var pressedNormalKeyQcodes: Set<String> = []

    /// NSEvent local monitor (process-global hook), 专治"按住 cmd 时字符键 keyUp 不送 view"
    /// 这个 macOS 已知行为. UTM 同款做法: 在 keyUp + modifierFlags.contains(.command)
    /// 时把 event 直接转发给本 view 的 keyUp(with:), 绕过 NSWindow 的丢弃.
    /// 进 / 出 window 时 install / uninstall, 防 monitor 泄漏到 view 销毁后还活着.
    private var cmdKeyUpMonitor: Any?

    /// 当前是否藏了 host 鼠标. NSCursor.hide/unhide 是引用计数 (HIToolbox 内部),
    /// 多 hide 没匹配 unhide 鼠标会一直消失; view 销毁前必须保证净 hide 计数 = 0.
    private var cursorHidden = false

    /// guest 通过 HDP CURSOR_DEFINE 推过来的硬件光标 (viogpudo / virtio-gpu cursor virtqueue).
    /// 跟 BDD 软件画法不同: hardware cursor 不在 framebuffer 像素里, host 必须自画 overlay.
    /// host 鼠标 ↔ guest tablet 走 usb-tablet 1:1 绝对坐标, host 鼠标位置即 guest 位置,
    /// 所以光标位置不用我们维护 — 让 macOS 自己跟踪 host 鼠标 + 我们替换 cursor 图像即可.
    private var guestCursor: NSCursor?
    /// guest 主动隐藏光标 (CURSOR_POS.visible=false). 此时 host 也跟着藏, 光标重新出现要等 visible=true.
    private var guestCursorHidden: Bool = false
    /// view 内/外标记. mouseEntered/Exited 维护; 决定要不要立即生效 cursor 替换.
    private var isMouseInside: Bool = false

    /// guest framebuffer 实际像素尺寸. bindSurface 时缓存, viewCoords 用来算 letterbox
    /// 区域 — host 鼠标坐标按 letterbox 区域归一化, 不算上下/左右黑边, 否则 view 整尺寸
    /// 归一化会让 guest 鼠标位置跟视觉错位.
    private var guestFbSize: CGSize = .zero


    /// 输入捕获总开关. 默认 true; 设 false 时:
    ///   - acceptsFirstResponder = false (键盘事件 fall through 给 NSWindow / 别的 control)
    ///   - mouse/key/scroll 处理函数全部直接 return, 不发 forwarder
    ///   - 不隐藏 host 鼠标 (mouseEntered 跳过 hide); 切 false 瞬间立即还原
    ///   - 立即释放当前 first responder, 防止键盘事件残留 routing 到本 view
    ///   - 如果当前 captured, 自动 releaseCapture (退回 released)
    /// 主用途: 同 VM 有独立窗口 (detached) 时, 主窗口的嵌入 view 让出输入,
    /// 用户操作完全在独立窗口里完成, 避免主窗口意外抢 mouse/key 焦点.
    public var inputCaptureEnabled: Bool = true {
        didSet {
            guard oldValue != inputCaptureEnabled else { return }
            if !inputCaptureEnabled {
                if isCaptured { releaseCapture() }
                releaseAllPressedKeys()
                if window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
                showHostCursor()
            } else if isMouseInside {
                // 重新 capture 且鼠标已在 view 内: 重新生效 cursor 替换
                applyCurrentCursor()
            }
        }
    }

    /// macOS 风格快捷键: host `cmd` 当 guest `ctrl` 转发 (cmd+c → ctrl+c).
    /// 默认 true. 副作用: 失去发 Win/super 键的能力 (Win11 开始菜单要鼠标点).
    /// 关闭后回到老逻辑 (cmd → meta_l/Win 键, 用户用 control+c 复制).
    /// 由 caller (DetailContainerView / DetachedVMWindowController) 在 view 创建后按
    /// VMConfig.macStyleShortcuts 设置.
    public var macStyleShortcuts: Bool = true

    /// host → guest 文件粘贴 closure.
    /// keyDown 拦到 Cmd+V 且 NSPasteboard 有 file URLs 时调; closure 由 GUI 层注入,
    /// 内部通常走 Task.detached → IPC clipboard.paste-files → VMHost FilePasteBridge.
    /// 仅 macStyleShortcuts=true 时拦截 (跟用户"Cmd 当主操作键"的预期一致).
    /// closure 调用即视为已"吃掉"这次 Cmd+V — view 不再发 keystroke 给 guest.
    public var onFilePaste: (([URL]) -> Void)?

    // MARK: - 键盘捕获双态

    /// captured 模式标记 (false = released, 默认).
    ///
    /// **进入 captured** (Cmd+Opt toggle):
    ///   1. CGSSetGlobalHotKeyOperatingMode(.disable) — macOS 全局热键失效, cmd+tab /
    ///      cmd+space 等全部送进 first responder (本 view) → guest
    ///   2. 显示 capture overlay 提示 "按 Cmd+Opt 退出捕获"
    ///   3. 清光所有 pressed keys (Cmd+Opt 本身不送 guest, 当 meta 用)
    ///
    /// **退出 captured** (再按 Cmd+Opt, 或 inputCaptureEnabled=false, 或失焦):
    ///   1. CGSSetGlobalHotKeyOperatingMode(.enable) — 还原系统热键
    ///   2. 隐藏 overlay
    ///   3. 清光所有 pressed keys (避免 modifier 卡键)
    ///
    /// **不**改变鼠标行为 (始终 abs 模式, host 鼠标位置 = guest 鼠标位置),
    /// 因为 QEMU usb-tablet 只支持 abs. captured 仅控制键盘抢占程度.
    public private(set) var isCaptured: Bool = false

    /// captured 时显示的右上角小标签. 由 setupCaptureOverlay 创建, captureInput /
    /// releaseCapture 切显示态.
    private var captureOverlay: NSView?

    /// MTKView 必须直接是嵌入主窗口的 view, 不能放在普通 NSView 内 — 否则
    /// AppKit 在 NSHostingView 的 layout 切换中触发 viewWillMoveToWindow /
    /// viewDidMoveToWindow 会让 MTKView 内部的 CVDisplayLink 失效, draw(in:)
    /// 永远不被调用 → 画面卡死. hell-vm 同款做法.
    /// forwarder 由 fanout 在 addSubscriber 时注入 (weak), 多 view 共享.
    public init(frame frameRect: NSRect) {
        let r = FramebufferRenderer()
        self.renderer = r
        super.init(frame: frameRect, device: r.device)
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        wantsLayer = true
        autoResizeDrawable = true
        translatesAutoresizingMaskIntoConstraints = false
        // 60Hz displayLink-driven auto draw (UTM 同款做法, MTKView 默认行为).
        // **不**启用 enableSetNeedsDisplay — 那会把 view 切成"仅 needsDisplay 才 draw"
        // 模式, NSWindow resize 后 guest 静止 (没新 SURFACE_DAMAGE) 时 view 立即停绘
        // 卡在最后一帧, 用户拖 detached 窗口改分辨率后画面冻死. 60Hz 持续 present 是
        // Metal triangle-strip 廉价操作, Apple Silicon UMA 下 CPU 占用 < 2%.
        preferredFramesPerSecond = 60
        isPaused = false
        delegate = self
        setupCaptureOverlay()
        setupDropOverlay()
        // host → guest 文件拖放接入. 复用 Cmd+V 后端通路,
        // 只接 file URLs (拒非 file URL / 文本 / 图片).
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("storyboard init unsupported") }

    // MARK: - public

    /// 接 SURFACE_NEW 事件: 把 fd 转交给 renderer mmap + 建纹理.
    /// @MainActor: renderer.bindShm 改写 draw(in:) 读的属性, 必须串行在 main thread.
    @MainActor
    public func bindSurface(_ arrival: DisplayChannel.SurfaceArrival) {
        renderer.bindShm(fd: arrival.shmFD, info: arrival.info)
        guestFbSize = CGSize(width: Int(arrival.info.width),
                              height: Int(arrival.info.height))
        // 新 surface 立即触发首帧 draw, 不等 surfaceDamage.
        needsDisplay = true
    }

    /// 接 SURFACE_DAMAGE 事件: 异步 schedule 一次 draw (绝对禁止用 view.draw() 同步,
    /// 它会 block main thread 整个 UI 冻住). setNeedsDisplay 是 idempotent, AppKit
    /// 会自动合并 burst damage 到下一次 displayLink tick.
    @MainActor
    public func markFramebufferDirty() {
        setNeedsDisplay(bounds)
    }

    /// 接 LED_STATE 事件: 用 ground truth 校正 expectedGuestCaps.
    public func updateGuestLEDState(_ leds: HDP.LedState) {
        expectedGuestCaps = leds.capsLock
    }

    /// 接 HDP CURSOR_DEFINE: 把 BGRA pixels 装成 NSCursor; mouse inside 时立即 set.
    /// 失败 (无 pixels / 无效 width-height) 退化到 NSCursor.arrow.
    @MainActor
    public func applyGuestCursorDefine(_ def: HDP.CursorDefine) {
        guestCursor = Self.makeCursor(from: def)
        if isMouseInside, inputCaptureEnabled {
            applyCurrentCursor()
        }
    }

    /// 接 HDP CURSOR_POS: x/y 不用 (host 鼠标位置 = guest, usb-tablet 1:1);
    /// 仅消费 visible — guest 主动藏光标时 host 也跟着藏, 重新可见时还原 guestCursor.
    @MainActor
    public func applyGuestCursorPos(_ pos: HDP.CursorPos) {
        let visible = (pos.visible != 0)
        guard visible != !guestCursorHidden else { return }
        guestCursorHidden = !visible
        if isMouseInside, inputCaptureEnabled {
            applyCurrentCursor()
        }
    }

    /// 把 BGRA cursor data 转 NSCursor. premultipliedFirst+byteOrder32Little 在 little-endian
    /// (Apple Silicon) 下内存布局即 BGRA (b0=B, b1=G, b2=R, b3=A), 跟 wire 格式对齐.
    private static func makeCursor(from def: HDP.CursorDefine) -> NSCursor? {
        let w = Int(def.width), h = Int(def.height)
        guard w > 0, h > 0, def.pixelsBGRA.count >= w * h * 4 else { return nil }
        guard let provider = CGDataProvider(data: def.pixelsBGRA as CFData) else { return nil }
        let bitmap = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let cg = CGImage(width: w, height: h,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: bitmap,
                                provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        let hot = NSPoint(x: max(0, Int(def.hotX)), y: max(0, Int(def.hotY)))
        return NSCursor(image: img, hotSpot: hot)
    }

    /// 在 mouse 仍在 view 内 + 仍 capture 的前提下把 cursor 状态推到 macOS.
    /// 三态: guest 隐藏 → NSCursor.hide(); guest 有自画 → set 我们的 NSCursor; 都没有 → hide host.
    private func applyCurrentCursor() {
        if guestCursorHidden {
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
            return
        }
        if let gc = guestCursor {
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
            gc.set()
        } else {
            // BDD 软件路径 (老 ramfb-only): cursor 已在 framebuffer 里, host 鼠标必须藏
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        }
    }

    // MARK: - first responder

    public override var acceptsFirstResponder: Bool { inputCaptureEnabled }
    public override func becomeFirstResponder() -> Bool {
        guard inputCaptureEnabled else { return false }
        // 重获焦点时立即 sync 当前实时 modifier 状态:
        // 用户在失焦期间按/松了某些 modifier (例如按住 cmd 切回来), view 内部 lastModifiers
        // 是过期的, 不 sync 的话 guest 端 cmd 永远没 keyDown, cmd+s 不生效.
        syncModifiersToGuest(NSEvent.modifierFlags)
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let opts: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited,
            .activeInKeyWindow, .inVisibleRect,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts,
                                        owner: self, userInfo: nil))
    }

    // MARK: - mouse

    /// 把 NSEvent 的 windowLocation 转成本 view 内的像素坐标 (左上原点).
    /// QEMU `usb-tablet` / `virtio-tablet` 期望左上原点.
    ///
    /// **letterbox 修正**: FramebufferRenderer 按 guest framebuffer 比例等比缩放
    /// 居中渲染到 drawable, 黑边在 view 上下或左右. 鼠标归一化必须按 letterbox 区域,
    /// 不能按整 view — 否则 host 鼠标在 view 中央时, guest 收到的归一化坐标偏 (因为
    /// 黑边占了部分 view 空间但 guest 视野里没有).
    /// guestFbSize 还没 bind 时退化到整 view 比例 (画面也没出来, 视觉对齐没影响).
    private func viewCoords(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let viewW = bounds.width
        let viewH = bounds.height
        // 翻 Y 到左上原点
        let yTop = viewH - p.y

        let gw = guestFbSize.width
        let gh = guestFbSize.height
        if gw > 0, gh > 0, viewW > 0, viewH > 0 {
            let scale = min(viewW / gw, viewH / gh)
            let lbW = gw * scale
            let lbH = gh * scale
            let lbX = (viewW - lbW) / 2
            let lbY = (viewH - lbH) / 2
            // 把 host 鼠标转 letterbox 内坐标; 在黑边里 clamp 到 letterbox 边缘.
            let cx = max(0, min(lbW, p.x - lbX))
            let cy = max(0, min(lbH, yTop - lbY))
            forwarder?.setViewSize(width: Double(lbW), height: Double(lbH))
            return (Double(cx), Double(cy))
        }
        forwarder?.setViewSize(width: Double(viewW), height: Double(viewH))
        return (Double(p.x), Double(yTop))
    }

    public override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        guard inputCaptureEnabled else { return }
        applyCurrentCursor()
    }
    public override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        showHostCursor()
    }

    private func showHostCursor() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    /// view 离开 window hierarchy 时收尾 (forwarder 生命周期由 fanout 管, 跟
    /// view 进出 window 解耦):
    ///   1. 退出 captured (防止 macOS 全局热键留在 disable 状态)
    ///   2. 补发所有 stuck normal key + modifier keyUp (防 guest 卡键)
    ///   3. 释放 first responder, 让键盘事件重新交回主 window
    ///   4. 还原 host 鼠标 (mouseEntered 隐了之后没 mouseExited 路径会把鼠标卡死)
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            if isCaptured { releaseCapture() }
            releaseAllPressedKeys()
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            showHostCursor()
            uninstallCmdKeyUpMonitor()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installCmdKeyUpMonitor()
            layoutCaptureOverlay()
        }
    }

    /// AppKit 因任何原因 (用户点别处 / 别的 view 抢) 让本 view 失去 first
    /// responder 时, 释放 capture (避免在别的 view 操作期间 macOS 全局热键仍被禁) +
    /// 补发 stuck key keyUp.
    public override func resignFirstResponder() -> Bool {
        if isCaptured { releaseCapture() }
        releaseAllPressedKeys()
        return super.resignFirstResponder()
    }

    public override func mouseMoved(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseMove(viewX: x, viewY: y)
    }
    public override func mouseDragged(with event: NSEvent)      { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseDown(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.left, down: true, viewX: x, viewY: y)
    }
    public override func mouseUp(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.left, down: false, viewX: x, viewY: y)
    }
    public override func rightMouseDown(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.right, down: true, viewX: x, viewY: y)
    }
    public override func rightMouseUp(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.right, down: false, viewX: x, viewY: y)
    }
    public override func otherMouseDown(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.middle, down: true, viewX: x, viewY: y)
    }
    public override func otherMouseUp(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let (x, y) = viewCoords(event)
        forwarder?.mouseButton(.middle, down: false, viewX: x, viewY: y)
    }
    public override func scrollWheel(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let dy = event.scrollingDeltaY
        guard abs(dy) >= 0.1 else { return }
        let (x, y) = viewCoords(event)
        let dir: InputForwarder.ScrollDirection = (dy > 0) ? .up : .down
        forwarder?.scrollWheel(dir, viewX: x, viewY: y)
    }

    // MARK: - keyboard

    public override func keyDown(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        syncCapsLockIfNeeded(modifierFlags: event.modifierFlags)
        if event.isARepeat { return }  // 不发 repeat, guest 自己 repeat

        // 文件粘贴拦截 (Cmd+V + NSPasteboard 有 file URLs):
        //   - 仅 macStyleShortcuts=true 拦 (用户在用 mac 习惯, Cmd 当 ctrl/主操作键)
        //   - 排除 Cmd+Opt+V (Opt 跟 Cmd 同按是 capture toggle 副产物, 不抢)
        //   - 排除 Shift / Ctrl 组合 (Cmd+Shift+V 等是其他业务快捷键)
        //   - NSPasteboard 没 file URLs → 走老路径 (cmd+v → ctrl+v 文本粘贴)
        // 注: 这里在 normal-key qcode 发送之前判断, 避免双发.
        if macStyleShortcuts,
           let onFilePaste,
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "v" {
            if let urls = Self.readPasteboardFileURLs(), !urls.isEmpty {
                onFilePaste(urls)
                return  // *不* 走 keystroke 路径; closure 已 own 这次 Cmd+V
            }
        }

        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            forwarder?.keyDown(qcode: qcode)
            pressedNormalKeyQcodes.insert(qcode)
        }
    }

    /// 读 NSPasteboard 里的 file URLs. 仅取 isFileURL = true 的, 排除 https / RTF 等
    /// 其他 NSURL 写入者. 没有 file URLs 返 nil 让 caller 走老路径 (文本粘贴).
    private static func readPasteboardFileURLs() -> [URL]? {
        let pb = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return urls
        }
        return nil
    }
    public override func keyUp(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            forwarder?.keyUp(qcode: qcode)
            pressedNormalKeyQcodes.remove(qcode)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        let cur = event.modifierFlags

        // Cmd+Opt toggle capture (UTM 风格释放/捕获快捷键). 跟 Cmd+Ctrl 老快捷键
        // 不同, 后者跟 Mission Control / 截图 / 第三方 app 严重冲突.
        // 检测条件: cmd+opt 同时刚按下 (cur 含两者, prev 不全含). prev 用 lastModifiers.
        let toggle: NSEvent.ModifierFlags = [.command, .option]
        let bothNow = cur.intersection(toggle) == toggle
        let bothPrev = lastModifiers.intersection(toggle) == toggle
        if bothNow && !bothPrev {
            if isCaptured {
                releaseCapture()
            } else {
                captureInput()
            }
            // toggle 路径不走正常 diff (Cmd+Opt 本身不送 guest, 当 meta 用):
            // captureInput / releaseCapture 内已经 releaseAllPressedKeys + reset
            // lastModifiers = []. 后续用户松开 cmd 或 opt 时 set diff 自然干净.
            return
        }

        // Caps Lock: 不在 flagsChanged 里发 toggle 给 guest. 因为发了 toggle 后
        // guest LED state 异步回传更新, 紧接着 keyDown 路径上的 syncCapsLockIfNeeded
        // 又看 host bit vs guest LED 不一致 → 重复 toggle 抵消. 单一 source: keyDown
        // 时统一查 expectedGuestCaps 同步.

        // 正常 modifier diff. syncModifiersToGuest 内会按 left/right 拆 qcode,
        // 维护 pressedModifierQcodes, 一并更新 lastModifiers.
        syncModifiersToGuest(cur)
    }

    /// 把 NSEvent.ModifierFlags 转成应发给 guest 的 qcode 集合.
    /// 左右修饰键区分: NSEvent.ModifierFlags 的 raw bit 区分左右 (0x2=leftShift,
    /// 0x4=rightShift, 等), 跟 UTM 私有扩展 + Carbon kVK_RightShift 等对齐.
    /// macStyleShortcuts=true 时 cmd → ctrl (左右独立), 用户期望 cmd+c=ctrl+c.
    private func modifierQcodes(from flags: NSEvent.ModifierFlags) -> Set<String> {
        var s: Set<String> = []
        if flags.contains(.leftShift)    { s.insert("shift") }
        if flags.contains(.rightShift)   { s.insert("shift_r") }
        // 兜底: 某些 NSEvent (合成事件 / 远程键盘) 只设 .shift 不设 left/right bit
        if flags.contains(.shift), !flags.contains(.leftShift), !flags.contains(.rightShift) {
            s.insert("shift")
        }

        if flags.contains(.leftControl)  { s.insert("ctrl") }
        if flags.contains(.rightControl) { s.insert("ctrl_r") }
        if flags.contains(.control), !flags.contains(.leftControl), !flags.contains(.rightControl) {
            s.insert("ctrl")
        }

        if flags.contains(.leftOption)   { s.insert("alt") }
        if flags.contains(.rightOption)  { s.insert("alt_r") }
        if flags.contains(.option), !flags.contains(.leftOption), !flags.contains(.rightOption) {
            s.insert("alt")
        }

        if flags.contains(.leftCommand) || flags.contains(.rightCommand) {
            // macStyleShortcuts: 左右 cmd 都映射成 ctrl (用户记忆里 cmd 是"主操作键",
            // 不区分左右). 关闭时 → meta_l (Win 键), 同样不区分.
            // 注: 这里 set 自动去重 — 用户同时按左 cmd 和 ctrl 时, target 已含 "ctrl",
            // 不会重复 keyDown.
            if macStyleShortcuts {
                s.insert("ctrl")
            } else {
                if flags.contains(.rightCommand) { s.insert("meta_r") } else { s.insert("meta_l") }
            }
        } else if flags.contains(.command),
                  !flags.contains(.leftCommand),
                  !flags.contains(.rightCommand) {
            // 同上兜底
            s.insert(macStyleShortcuts ? "ctrl" : "meta_l")
        }
        return s
    }

    /// 把当前 host 期望的 modifier 状态推给 guest: 当前已发 set 跟 target diff,
    /// 多的发 keyUp, 少的发 keyDown. 同步更新 pressedModifierQcodes + lastModifiers.
    /// forwarder 未连时不发 (但 lastModifiers 仍更新, 等 forwarder 上线后 becomeFirstResponder
    /// 再次同步).
    private func syncModifiersToGuest(_ flags: NSEvent.ModifierFlags) {
        let target = modifierQcodes(from: flags)
        if let fw = forwarder {
            for q in pressedModifierQcodes.subtracting(target) {
                fw.keyUp(qcode: q)
            }
            for q in target.subtracting(pressedModifierQcodes) {
                fw.keyDown(qcode: q)
            }
            pressedModifierQcodes = target
        }
        lastModifiers = flags
    }

    /// 装 NSEvent local monitor 拦截 keyUp-with-cmd (macOS 已知行为: 按住 .command 时
    /// 字符键 keyUp 不送 NSView, 后果是 guest 看 keyDown 没对应 keyUp → auto-repeat 卡键).
    /// 直接把 event 路由给 self.keyUp, 然后 return event 让 NSApp 自由 dispatch (不影响其他).
    /// guard: 仅本 view 是 first responder + 输入捕获 + 修饰含 cmd 才 take over,
    /// 否则放行 (避免主嵌入 + detached 双 view 抢 keyUp 路由).
    private func installCmdKeyUpMonitor() {
        guard cmdKeyUpMonitor == nil else { return }
        cmdKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self else { return event }
            if self.inputCaptureEnabled,
               self.window?.firstResponder === self,
               event.modifierFlags.contains(.command) {
                self.keyUp(with: event)
            }
            return event
        }
    }

    private func uninstallCmdKeyUpMonitor() {
        if let m = cmdKeyUpMonitor {
            NSEvent.removeMonitor(m)
            cmdKeyUpMonitor = nil
        }
    }

    /// 一次性补发所有 stuck modifier + normal key 的 keyUp + 清状态.
    /// 在 view 即将丢 first responder / 离开 window / 进出 captured 模式时调用,
    /// 避免 guest 看到 keyDown 没对应 keyUp → keyboard auto-repeat 卡键 (例如
    /// Win11 OOBE 阶段 Tab 一直切焦点循环 "支持/下一步/上一步", 或者 shift 永远
    /// 当成按下).
    /// 老 bug 根治点: 之前只清 normal key 不清 modifier, 用户 cmd+tab 切走再回来
    /// guest 端 cmd 永远 keyDown, 看起来就是"cmd 一直按着".
    private func releaseAllPressedKeys() {
        if let fw = forwarder {
            for qcode in pressedNormalKeyQcodes {
                fw.keyUp(qcode: qcode)
            }
            for qcode in pressedModifierQcodes {
                fw.keyUp(qcode: qcode)
            }
        }
        pressedNormalKeyQcodes.removeAll()
        pressedModifierQcodes.removeAll()
        lastModifiers = []
    }

    // MARK: - 捕获双态切换

    /// 进入 captured 模式: 禁用 macOS 全局热键 + 显示 overlay 提示 + 清光 pressed
    /// keys (防止 Cmd+Opt 触发本身的两个 modifier 卡在 guest 端).
    private func captureInput() {
        guard !isCaptured else { return }
        releaseAllPressedKeys()
        HVMSetGlobalHotKeyOperatingMode(.disable)
        isCaptured = true
        captureOverlay?.isHidden = false
    }

    /// 退出 captured 模式: 还原 macOS 全局热键 + 隐藏 overlay + 清 pressed keys.
    /// 任何路径 (用户再按 Cmd+Opt / view 失焦 / view 销毁 / inputCaptureEnabled=false)
    /// 都必须经过这里, 否则系统热键留在 disable 状态用户无法 cmd+tab 切到别的 app.
    private func releaseCapture() {
        guard isCaptured else { return }
        releaseAllPressedKeys()
        HVMSetGlobalHotKeyOperatingMode(.enable)
        isCaptured = false
        captureOverlay?.isHidden = true
    }

    // MARK: - captured 状态视觉反馈

    /// 右上角小标签 "⌘⌥ 退出捕获". captured 时显示, released 时隐藏.
    /// 走原生 NSTextField + NSVisualEffectView (HUD 风格), 不引 SwiftUI overlay
    /// (FramebufferHostView 是 MTKView, 直接 addSubview 更简单).
    private func setupCaptureOverlay() {
        let label = NSTextField(labelWithString: "⌘⌥  退出捕获")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.drawsBackground = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.isHidden = true

        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -5),
        ])
        addSubview(bg)
        captureOverlay = bg
        layoutCaptureOverlay()
    }

    /// 把 overlay pin 到右上角. 在 viewDidMoveToWindow / layoutSubtreeIfNeeded 时
    /// 重新约束, 防止 view bounds 变化后 overlay 跑偏 (autoresizing mask 在 MTKView
    /// 这种 layer-backed 子类有时不稳).
    private func layoutCaptureOverlay() {
        guard let bg = captureOverlay else { return }
        // 移除旧约束 (constant 改了不重新 activate 也行, 但为了 bounds 变化时位置稳, 重建)
        NSLayoutConstraint.deactivate(bg.constraints.filter {
            $0.firstAnchor === bg.topAnchor || $0.firstAnchor === bg.trailingAnchor
        })
        NSLayoutConstraint.activate([
            bg.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
            bg.topAnchor.constraint(equalTo: self.topAnchor, constant: 10),
        ])
    }

    // MARK: - 文件拖放
    //
    // 跟 Cmd+V 共一条后端: drag perform 时调 onFilePaste(urls) 闭包, 走同样的
    // AppModel.pasteFilesToVM → IPC clipboard.paste-files → FilePasteBridge 通路.
    // 这里只负责:
    //   1. 接受范围 (仅 fbView, 仅 inputCaptureEnabled + macStyleShortcuts + 有 onFilePaste 闭包)
    //   2. 视觉反馈 (dropOverlay 半透明黑底 + 中央 hint 文字)
    //   3. URLs 抽取 (跟 Cmd+V 同 urlReadingFileURLsOnly 过滤)

    /// drag-enter 时显示的中央高亮 hint. setupDropOverlay 创建, draggingEntered / Exited
    /// 切显隐.
    private var dropOverlay: NSView?
    private var dropOverlayLabel: NSTextField?

    private func setupDropOverlay() {
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        bg.layer?.borderWidth = 3
        bg.layer?.borderColor = NSColor.controlAccentColor.cgColor
        bg.layer?.cornerRadius = 12
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.isHidden = true

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -20),
        ])

        addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: self.topAnchor, constant: 16),
            bg.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -16),
            bg.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 16),
            bg.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -16),
        ])
        dropOverlay = bg
        dropOverlayLabel = label
    }

    /// 拖入接受判定 + 视觉反馈. 三条全过才接受:
    ///   1. inputCaptureEnabled (跟 Cmd+V 同, dialog / detached 副作用一致)
    ///   2. macStyleShortcuts (用户走 mac 习惯; 关掉就当不 拒)
    ///   3. onFilePaste 已注入 (运行中 VM 才有这条闭包)
    ///   4. 拖的 pasteboard 含至少 1 个 file URL
    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = filePasteboardURLs(from: sender), !urls.isEmpty else {
            return []
        }
        showDropOverlay(count: urls.count)
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // dragEnter 已算过, update 用同结果 (不每帧重读 pasteboard, 省 CPU)
        guard dropOverlay?.isHidden == false else { return [] }
        return .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hideDropOverlay()
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { hideDropOverlay() }
        guard let urls = filePasteboardURLs(from: sender), !urls.isEmpty else {
            return false
        }
        guard let onFilePaste else { return false }
        onFilePaste(urls)
        return true
    }

    /// 从 NSDraggingInfo 抽出 file URLs (仅 file URL, 排 https / RTF 等其他 NSURL).
    /// guard inputCaptureEnabled + macStyleShortcuts + 有闭包; 任一不过返 nil 让 caller 拒.
    private func filePasteboardURLs(from sender: any NSDraggingInfo) -> [URL]? {
        guard inputCaptureEnabled, macStyleShortcuts, onFilePaste != nil else { return nil }
        let pb = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else {
            return nil
        }
        return urls
    }

    private func showDropOverlay(count: Int) {
        dropOverlayLabel?.stringValue = "释放鼠标 — 把 \(count) 个文件拖到虚拟机"
        dropOverlay?.isHidden = false
    }

    private func hideDropOverlay() {
        dropOverlay?.isHidden = true
    }

    /// 仅供 GUI probe 测试用: 主动切 dropOverlay 显示状态 (绕过真实 drag 流程, 给截图验证用).
    public func probeShowDropOverlay(count: Int) { showDropOverlay(count: count) }
    public func probeHideDropOverlay() { hideDropOverlay() }

    /// CapsLock 双端同步: host 与 expectedGuestCaps 不一致时给 guest 发一次
    /// caps_lock toggle 让对齐, 同步翻转 expectedGuestCaps 不等 LED_STATE 回传 (避免
    /// 异步回传延迟造成的双重 toggle race). LED_STATE 仍会校正 expectedGuestCaps
    /// 处理乱序场景 (例如 guest 内用户用屏幕键盘改了 caps).
    private func syncCapsLockIfNeeded(modifierFlags: NSEvent.ModifierFlags) {
        let hostOn = modifierFlags.contains(.capsLock)
        if hostOn != expectedGuestCaps {
            forwarder?.keyDown(qcode: "caps_lock")
            forwarder?.keyUp(qcode: "caps_lock")
            expectedGuestCaps = hostOn
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 注: 不在这里 setViewSize. letterbox 后整 view 尺寸跟鼠标归一化用的 letterbox
        // 区域不一致, viewCoords 在每次鼠标事件里按 letterbox 实时算 + setViewSize, 这条
        // drawable resize 路径同步是多余而且可能错误 (会把整 view 尺寸覆盖到 forwarder).
        // drawable 尺寸 (backing pixel, 已乘 retina scale) 推给上层, 上层
        // 通过 RESIZE_REQUEST → QEMU dpy_set_ui_info → EDID 让 guest vdagent
        // 自动改分辨率 (guest 须装 spice-vdagent).
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        onDrawableSizeChange?(w, h)
    }

    public func draw(in view: MTKView) {
        renderer.draw(in: view)
    }
}

// MARK: - NSEvent.ModifierFlags 左右键区分扩展

/// NSEvent.ModifierFlags 的公开 API 不区分左右修饰键, 但 raw bit 区分 (跟 Carbon
/// kEventKeyModifier* 同源). UTM VMMetalView 用相同 raw bit 做左右区分, 我们照搬.
///
/// 各 bit 来源: Carbon `Events.h` + macOS `NSEvent.h` 私有定义, 历史稳定 (跨 macOS
/// 10.5 ~ 15+ 都没变). 不公开是 Apple 不愿承诺 API stability, 但实际从未变过.
private extension NSEvent.ModifierFlags {
    static var leftShift:    NSEvent.ModifierFlags { .init(rawValue: 0x0002) }
    static var rightShift:   NSEvent.ModifierFlags { .init(rawValue: 0x0004) }
    static var leftControl:  NSEvent.ModifierFlags { .init(rawValue: 0x0001) }
    static var rightControl: NSEvent.ModifierFlags { .init(rawValue: 0x2000) }
    static var leftOption:   NSEvent.ModifierFlags { .init(rawValue: 0x0020) }
    static var rightOption:  NSEvent.ModifierFlags { .init(rawValue: 0x0040) }
    static var leftCommand:  NSEvent.ModifierFlags { .init(rawValue: 0x0008) }
    static var rightCommand: NSEvent.ModifierFlags { .init(rawValue: 0x0010) }
}
