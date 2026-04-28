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

import Foundation
import AppKit
import MetalKit

public final class FramebufferHostView: MTKView, MTKViewDelegate {

    public let renderer: FramebufferRenderer

    /// 输入转发器, 由 attach 方法注入. weak 防循环.
    public weak var inputForwarder: InputForwarder?

    /// view drawable 尺寸改变时回调, 通常上层 (QemuEmbeddedSession) 接到后
    /// 调 DisplayChannel.requestResize 给 guest 改分辨率 (要求 guest 装 vdagent).
    /// 参数是 drawable pixel 尺寸 (已乘 backingScaleFactor, 给 guest 的真实分辨率).
    public var onDrawableSizeChange: ((UInt32, UInt32) -> Void)?

    /// 我们预期 guest CapsLock 当前状态. 每次发 caps_lock toggle 翻转;
    /// 收到 LED_STATE 时用 ground truth 校正. 这是单一 source 避免 LED_STATE
    /// 回传延迟造成的双重 toggle race.
    private var expectedGuestCaps: Bool = false

    /// 上一次 NSEvent.modifierFlags 全量, 用于 flagsChanged 算 diff (修饰键 down/up)
    private var lastHostFlags: NSEvent.ModifierFlags = []

    /// 当前是否藏了 host 鼠标. NSCursor.hide/unhide 是引用计数 (HIToolbox 内部),
    /// 多 hide 没匹配 unhide 鼠标会一直消失; view 销毁前必须保证净 hide 计数 = 0.
    private var cursorHidden = false

    /// MTKView 必须直接是嵌入主窗口的 view, 不能放在普通 NSView 内 — 否则
    /// AppKit 在 NSHostingView 的 layout 切换中触发 viewWillMoveToWindow /
    /// viewDidMoveToWindow 会让 MTKView 内部的 CVDisplayLink 失效, draw(in:)
    /// 永远不被调用 → 画面卡死. hell-vm 同款做法.
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
        // displayLink 60Hz 保底 + setNeedsDisplay 额外触发: 收到 SURFACE_DAMAGE
        // 时 markFramebufferDirty 调 setNeedsDisplay 立即调度 draw, 即便 M3 Max
        // ProMotion 把 displayLink throttle 到 ~6Hz 也不会卡 (manual draw 唤醒).
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = true
        isPaused = false
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("storyboard init unsupported") }

    // MARK: - public

    /// 接 SURFACE_NEW 事件: 把 fd 转交给 renderer mmap + 建纹理.
    /// @MainActor: renderer.bindShm 改写 draw(in:) 读的属性, 必须串行在 main thread.
    @MainActor
    public func bindSurface(_ arrival: DisplayChannel.SurfaceArrival) {
        renderer.bindShm(fd: arrival.shmFD, info: arrival.info)
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

    // MARK: - first responder

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

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
    private func viewCoords(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        // NSView 默认 isFlipped = false, 原点左下; 我们要左上, 翻 Y.
        let y = bounds.height - p.y
        return (Double(p.x), Double(y))
    }

    public override func mouseEntered(with event: NSEvent) { hideHostCursor() }
    public override func mouseExited(with event: NSEvent)  { showHostCursor() }

    private func hideHostCursor() {
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }
    private func showHostCursor() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    /// view 离开 window hierarchy (VM 关闭 / tab 切换 / 主窗口关闭) 时:
    ///   1. 释放 first responder, 让键盘事件重新交回主 window
    ///   2. 还原 host 鼠标 (mouseEntered 隐了之后没 mouseExited 路径会把鼠标卡死)
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            showHostCursor()
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseMove(viewX: x, viewY: y)
    }
    public override func mouseDragged(with event: NSEvent)      { mouseMoved(with: event) }
    public override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.left, down: true, viewX: x, viewY: y)
    }
    public override func mouseUp(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.left, down: false, viewX: x, viewY: y)
    }
    public override func rightMouseDown(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.right, down: true, viewX: x, viewY: y)
    }
    public override func rightMouseUp(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.right, down: false, viewX: x, viewY: y)
    }
    public override func otherMouseDown(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.middle, down: true, viewX: x, viewY: y)
    }
    public override func otherMouseUp(with event: NSEvent) {
        let (x, y) = viewCoords(event)
        inputForwarder?.mouseButton(.middle, down: false, viewX: x, viewY: y)
    }
    public override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) >= 0.1 else { return }
        let (x, y) = viewCoords(event)
        let dir: InputForwarder.ScrollDirection = (dy > 0) ? .up : .down
        inputForwarder?.scrollWheel(dir, viewX: x, viewY: y)
    }

    // MARK: - keyboard

    public override func keyDown(with event: NSEvent) {
        syncCapsLockIfNeeded(modifierFlags: event.modifierFlags)
        if event.isARepeat { return }  // 不发 repeat, guest 自己 repeat
        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            inputForwarder?.keyDown(qcode: qcode)
        }
    }
    public override func keyUp(with event: NSEvent) {
        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            inputForwarder?.keyUp(qcode: qcode)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        let cur = event.modifierFlags
        let prev = lastHostFlags
        lastHostFlags = cur

        // VZ 风格快捷键: 同时按下 Cmd + Control → 释放 first responder,
        // 把键盘焦点交回 window, 后续事件不再被 framebuffer 拦截 (跟 HVMView /
        // VZVirtualMachineView 一致). 重新捕获: 点击 framebuffer 任意位置.
        // 释放时清掉所有 stuck guest modifier 防止 guest 卡在 cmd/ctrl down 状态.
        let release: NSEvent.ModifierFlags = [.command, .control]
        let bothNow = cur.intersection(release) == release
        let bothPrev = prev.intersection(release) == release
        if bothNow && !bothPrev {
            sendModifierUpAll(prev)
            window?.makeFirstResponder(nil)
            showHostCursor()  // 走 cursorHidden 计数, 防止跟 mouseExited 双调
            return
        }

        // 注: CapsLock 不在 flagsChanged 里发 toggle 给 guest. 因为发了
        // toggle 后 guest LED state 异步回传更新, 紧接着 keyDown 路径上的
        // syncCapsLockIfNeeded 又看 host bit vs guest LED 不一致 → 重复 toggle
        // 抵消. 单一 source: keyDown 时统一查 expectedGuestCaps 同步.

        // Shift / Control / Option / Command: 普通 down/up modifier.
        // NSEvent.ModifierFlags 不区分左右, 我们都映射到左侧 qcode (shift/ctrl/alt/meta_l).
        let map: [(NSEvent.ModifierFlags, String)] = [
            (.shift,   "shift"),
            (.control, "ctrl"),
            (.option,  "alt"),
            (.command, "meta_l"),
        ]
        for (flag, qcode) in map {
            let was = prev.contains(flag)
            let now = cur.contains(flag)
            if !was && now { inputForwarder?.keyDown(qcode: qcode) }
            if  was && !now { inputForwarder?.keyUp(qcode: qcode) }
        }
    }

    /// 释放 first responder 时给 guest 补 keyUp, 防止 stuck modifier (例如
    /// 用户按住 ctrl 按 cmd 触发 release, 没补 keyUp 的话 guest 会卡在 ctrl down).
    private func sendModifierUpAll(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift)   { inputForwarder?.keyUp(qcode: "shift") }
        if flags.contains(.control) { inputForwarder?.keyUp(qcode: "ctrl") }
        if flags.contains(.option)  { inputForwarder?.keyUp(qcode: "alt") }
        if flags.contains(.command) { inputForwarder?.keyUp(qcode: "meta_l") }
    }

    /// CapsLock 双端同步: host 与 expectedGuestCaps 不一致时给 guest 发一次
    /// caps_lock toggle 让对齐, 同步翻转 expectedGuestCaps 不等 LED_STATE 回传 (避免
    /// 异步回传延迟造成的双重 toggle race). LED_STATE 仍会校正 expectedGuestCaps
    /// 处理乱序场景 (例如 guest 内用户用屏幕键盘改了 caps).
    private func syncCapsLockIfNeeded(modifierFlags: NSEvent.ModifierFlags) {
        let hostOn = modifierFlags.contains(.capsLock)
        if hostOn != expectedGuestCaps {
            inputForwarder?.keyDown(qcode: "caps_lock")
            inputForwarder?.keyUp(qcode: "caps_lock")
            expectedGuestCaps = hostOn
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 鼠标坐标归一化用的是本 view 的尺寸, 保持同步.
        inputForwarder?.setViewSize(width: Double(bounds.width),
                                     height: Double(bounds.height))
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
