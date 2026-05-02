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

    /// 上一次 NSEvent.modifierFlags 全量, 用于 flagsChanged 算 diff (修饰键 down/up)
    private var lastHostFlags: NSEvent.ModifierFlags = []

    /// 当前已发给 guest 的 keyDown 但未发对应 keyUp 的 qcode 集合.
    /// 用途: 当 view 失去 first responder (例如用户按 Cmd+Ctrl 触发 release-capture
    /// 快捷键, 或主动切到别的 window) 时, AppKit 不再把后续 keyUp 事件送给本 view,
    /// guest 会卡在 "key 一直按下" 状态 → keyboard auto-repeat 让用户看到 Tab 一直
    /// 切焦点 / 字母一直输入这种灵异现象. 释放焦点前必须遍历此集合一次性补发 keyUp.
    private var pressedKeys: Set<String> = []

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
    /// 主用途: 同 VM 有独立窗口 (detached) 时, 主窗口的嵌入 view 让出输入,
    /// 用户操作完全在独立窗口里完成, 避免主窗口意外抢 mouse/key 焦点.
    public var inputCaptureEnabled: Bool = true {
        didSet {
            guard oldValue != inputCaptureEnabled else { return }
            if !inputCaptureEnabled {
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
    public override func becomeFirstResponder() -> Bool { inputCaptureEnabled }

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
    ///   1. 补发所有 stuck normal key keyUp (防 guest 卡键)
    ///   2. 释放 first responder, 让键盘事件重新交回主 window
    ///   3. 还原 host 鼠标 (mouseEntered 隐了之后没 mouseExited 路径会把鼠标卡死)
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            releaseAllPressedKeys()
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            showHostCursor()
        }
    }

    /// AppKit 因任何原因 (用户点别处 / 别的 view 抢) 让本 view 失去 first
    /// responder 时, 也要补发 stuck key keyUp; 否则 guest 卡键.
    public override func resignFirstResponder() -> Bool {
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
        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            forwarder?.keyDown(qcode: qcode)
            pressedKeys.insert(qcode)
        }
    }
    public override func keyUp(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
        if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
            forwarder?.keyUp(qcode: qcode)
            pressedKeys.remove(qcode)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        guard inputCaptureEnabled else { return }
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
            // 必须先补发所有 stuck normal key (Tab / 字母 etc) keyUp, 再发 modifier
            // keyUp, 最后释放 first responder. 顺序很关键: 先释放再发 keyUp, AppKit
            // 会把 key event 送给新 first responder (主 window) 而不是本 view, guest
            // 收不到 keyUp → 卡键 → user 看到 Tab 一直切焦点 / 字母一直输入.
            releaseAllPressedKeys()
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
            if !was && now { forwarder?.keyDown(qcode: qcode) }
            if  was && !now { forwarder?.keyUp(qcode: qcode) }
        }
    }

    /// 释放 first responder 时给 guest 补 keyUp, 防止 stuck modifier (例如
    /// 用户按住 ctrl 按 cmd 触发 release, 没补 keyUp 的话 guest 会卡在 ctrl down).
    private func sendModifierUpAll(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift)   { forwarder?.keyUp(qcode: "shift") }
        if flags.contains(.control) { forwarder?.keyUp(qcode: "ctrl") }
        if flags.contains(.option)  { forwarder?.keyUp(qcode: "alt") }
        if flags.contains(.command) { forwarder?.keyUp(qcode: "meta_l") }
    }

    /// 给所有已 keyDown 但未 keyUp 的 normal key (Tab / Return / 字母 / 数字 etc)
    /// 补发 keyUp + 清空状态. 在 view 即将丢 first responder / 离开 window 前调用,
    /// 避免 guest 看到 keyDown 没对应 keyUp → keyboard auto-repeat 卡键现象 (例如
    /// Win11 OOBE 阶段 Tab 一直切焦点循环 "支持/下一步/上一步").
    private func releaseAllPressedKeys() {
        guard !pressedKeys.isEmpty else { return }
        for qcode in pressedKeys {
            forwarder?.keyUp(qcode: qcode)
        }
        pressedKeys.removeAll()
    }

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
