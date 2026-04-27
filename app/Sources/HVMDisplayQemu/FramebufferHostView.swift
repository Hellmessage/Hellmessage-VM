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

public final class FramebufferHostView: NSView, MTKViewDelegate {

    private let mtkView: MTKView
    public let renderer: FramebufferRenderer

    /// 输入转发器, 由 attach 方法注入. weak 防循环.
    public weak var inputForwarder: InputForwarder?

    /// guest 最近上报的 LED 状态; CapsLock 同步用.
    private var guestLEDState = HDP.LedState(capsLock: false,
                                              numLock: false,
                                              scrollLock: false)

    /// 上一次 NSEvent.modifierFlags 全量, 用于 flagsChanged 算 diff (修饰键 down/up)
    private var lastHostFlags: NSEvent.ModifierFlags = []

    public override init(frame frameRect: NSRect) {
        self.renderer = FramebufferRenderer()
        let mtk = MTKView(frame: frameRect, device: renderer.device)
        mtk.framebufferOnly = true
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.preferredFramesPerSecond = 30
        mtk.translatesAutoresizingMaskIntoConstraints = false
        mtk.isPaused = false
        mtk.enableSetNeedsDisplay = false
        self.mtkView = mtk
        super.init(frame: frameRect)
        addSubview(mtk)
        NSLayoutConstraint.activate([
            mtk.topAnchor.constraint(equalTo: topAnchor),
            mtk.bottomAnchor.constraint(equalTo: bottomAnchor),
            mtk.leadingAnchor.constraint(equalTo: leadingAnchor),
            mtk.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mtk.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("storyboard init unsupported") }

    // MARK: - public

    /// 接 SURFACE_NEW 事件: 把 fd 转交给 renderer mmap + 建纹理.
    public func bindSurface(_ arrival: DisplayChannel.SurfaceArrival) {
        renderer.bindShm(fd: arrival.shmFD, info: arrival.info)
    }

    /// 接 LED_STATE 事件: 更新 guest LED 状态缓存.
    public func updateGuestLEDState(_ leds: HDP.LedState) {
        guestLEDState = leds
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

    public override func mouseEntered(with event: NSEvent) { NSCursor.hide() }
    public override func mouseExited(with event: NSEvent)  { NSCursor.unhide() }

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

        // CapsLock 是 toggle 类: NSEvent 不发 keyDown/keyUp, 只 flagsChanged.
        // 仅当 host CapsLock bit 翻转时, 让 guest toggle 一次.
        if cur.contains(.capsLock) != prev.contains(.capsLock) {
            inputForwarder?.keyDown(qcode: "caps_lock")
            inputForwarder?.keyUp(qcode: "caps_lock")
        }

        // Shift / Control / Option / Command: 普通 down/up modifier.
        // NSEvent.ModifierFlags 不区分左右, 我们都映射到左侧 qcode (shift/ctrl/alt/meta_l).
        // 如未来要左右独立, 可走 NSEvent.modifierFlags.contains(.deviceIndependentFlagsMask)
        // 加 deviceMask 区分.
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

    /// CapsLock 双端同步: host 与 guest LED 状态不一致时, 给 guest 补一次
    /// caps_lock toggle 让对齐. 防止 "host 大写, guest 小写" 的输入混乱.
    private func syncCapsLockIfNeeded(modifierFlags: NSEvent.ModifierFlags) {
        let hostOn  = modifierFlags.contains(.capsLock)
        let guestOn = guestLEDState.capsLock
        if hostOn != guestOn {
            inputForwarder?.keyDown(qcode: "caps_lock")
            inputForwarder?.keyUp(qcode: "caps_lock")
            // 不立即 set guestLEDState — 等下个 LED_STATE 消息回传刷新.
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 鼠标坐标归一化用的是本 view 的尺寸, 保持同步.
        inputForwarder?.setViewSize(width: Double(bounds.width),
                                     height: Double(bounds.height))
    }

    public func draw(in view: MTKView) {
        renderer.draw(in: view)
    }
}
