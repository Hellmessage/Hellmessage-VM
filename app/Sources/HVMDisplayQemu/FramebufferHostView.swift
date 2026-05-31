// FramebufferHostView.swift
//
// 主窗口右栏的 QEMU 嵌入视图. 职责:
//   1. 持有 MTKView, 由 FramebufferRenderer 在 draw(in:) 渲染当前 framebuffer
//   2. 拦截 NSEvent 键鼠 → InputForwarder (走独立 QMP socket)
//   3. CapsLock 同步: 接 LED_STATE 跟 host capsLock 比对, 不一致时强制 guest toggle 对齐
//   4. 鼠标进入隐藏 host cursor (guest 内有自己的硬件光标)
//
// 上层创建并 attach DisplayChannel + InputForwarder + FramebufferRenderer 三件套.
//
// ---- 键盘捕获双态 (UTM 风格) ----
//   released (默认): view 接键鼠, 但 macOS 系统快捷键 (Cmd+Tab / Mission Control / 截图)
//                    仍由 macOS 处理, 不进 guest.
//   captured:        Cmd+Opt 切换进入. CGSSetGlobalHotKeyOperatingMode(.disable) 禁用
//                    macOS 全局热键, 所有键 (含 cmd+tab) 全送 guest. 再按 Cmd+Opt 退回.
//
// 修饰键卡键防护三件套 (根治 "shift / cmd 一直按着" 老 bug):
//   * lastModifiers — NSEvent.ModifierFlags 镜像, flagsChanged 用 set diff 算 down/up
//   * pressedModifierQcodes — 已 keyDown 未 keyUp 的 modifier qcode 集合
//   * pressedNormalKeyQcodes — 同上, 非修饰键
//   resignFirstResponder / viewWillMove(toWindow:nil) / 进出 captured 时全部 keyUp + clear.
//   **禁止**只清 normal key 不清 modifier (否则 cmd+tab 切走再回 guest 卡 cmd down).

import Foundation
import AppKit
import MetalKit

public final class FramebufferHostView: MTKView, MTKViewDelegate {

    public let renderer: FramebufferRenderer

    /// 输入转发器, 由 fanout 注入 (weak).
    /// QEMU input QMP 是**单 client** chardev socket, 同 VM 多 view 共存时**必须共享同一
    /// InputForwarder 实例** (fanout 内 own), 不能各自连. 发 input 前 view 自己 setViewSize,
    /// NSEvent 一时刻只送一个 view, 串行无竞争.
    public weak var forwarder: InputForwarder?

    /// view drawable 尺寸改变时回调, 上层接到后调 DisplayChannel.requestResize 让 guest
    /// 改分辨率. 参数是 drawable pixel 尺寸 (已乘 backingScaleFactor). 非 resize master 的
    /// view (例如 detached 窗口) 保持 nil, 避免多 view 反复 resize 拉锯.
    public var onDrawableSizeChange: ((UInt32, UInt32) -> Void)?

    /// 预期 guest CapsLock 状态. 发 caps_lock toggle 时翻转, 收 LED_STATE 时用 ground truth
    /// 校正. 单一 source 避免 LED_STATE 回传延迟造成的双重 toggle race.
    private var expectedGuestCaps: Bool = false

    /// 上一次 NSEvent.modifierFlags 全量, flagsChanged 用 set diff 算 down/up.
    /// 进/出 captured 模式 + 失焦时 reset 为 [].
    private var lastModifiers: NSEvent.ModifierFlags = []

    /// 已 keyDown 未 keyUp 的 modifier qcode 集合 (例如 {"shift", "ctrl_r"}).
    /// resignFirstResponder / 失焦 / toggle capture 时一并 keyUp + clear, 防卡键.
    private var pressedModifierQcodes: Set<String> = []

    /// 已 keyDown 未 keyUp 的非修饰键 qcode 集合. 跟 pressedModifierQcodes 平行, 同时机清理.
    private var pressedNormalKeyQcodes: Set<String> = []

    /// NSEvent local monitor, 专治 macOS "按住 cmd 时字符键 keyUp 不送 view" 已知行为:
    /// keyUp + .command 时把 event 直接转给本 view 的 keyUp(with:). 进/出 window 时
    /// install / uninstall 防泄漏.
    private var cmdKeyUpMonitor: Any?

    /// 当前是否藏了 host 鼠标. NSCursor.hide/unhide 是引用计数, view 销毁前必须保证净
    /// hide 计数 = 0, 否则鼠标永久消失.
    private var cursorHidden = false

    /// guest 通过 HDP CURSOR_DEFINE 推的硬件光标. 不在 framebuffer 像素里, host 自画 overlay.
    /// host 鼠标 ↔ guest tablet usb-tablet 1:1 绝对坐标, 位置不用我们维护, 只替换 cursor 图像.
    private var guestCursor: NSCursor?
    /// guest 主动隐藏光标 (CURSOR_POS.visible=false), host 也跟着藏, 等 visible=true 还原.
    private var guestCursorHidden: Bool = false
    /// view 内/外标记. mouseEntered/Exited 维护; 决定要不要立即生效 cursor 替换.
    private var isMouseInside: Bool = false

    /// guest framebuffer 实际像素尺寸. viewCoords 用来算 letterbox 区域 — 鼠标坐标按
    /// letterbox 区域归一化, 不算黑边, 否则 guest 鼠标位置跟视觉错位.
    private var guestFbSize: CGSize = .zero


    /// 输入捕获总开关. 默认 true; 设 false 时让出输入: acceptsFirstResponder=false,
    /// mouse/key/scroll 处理直接 return, 不隐藏 host 鼠标, 释放 first responder, 自动
    /// releaseCapture. 主用途: 同 VM 有 detached 窗口时主窗口嵌入 view 让出焦点.
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

    /// macOS 风格快捷键: host `cmd` 当 guest `ctrl` 转发 (cmd+c → ctrl+c). 默认 true.
    /// 副作用: 失去发 Win/super 键的能力. 关闭后 cmd → meta_l/Win 键. 由 caller 按
    /// VMConfig.macStyleShortcuts 设置.
    public var macStyleShortcuts: Bool = true

    /// host → guest 文件粘贴 closure. keyDown 拦到 Cmd+V 且 NSPasteboard 有 file URLs 时调,
    /// 由 GUI 层注入 (内部走 IPC clipboard.paste-files → FilePasteBridge). 仅 macStyleShortcuts
    /// =true 时拦截. 调用即视为已"吃掉"这次 Cmd+V, view 不再发 keystroke.
    public var onFilePaste: (([URL]) -> Void)?

    // MARK: - 键盘捕获双态

    /// captured 模式标记 (false = released, 默认). Cmd+Opt toggle.
    ///   进入: CGSSetGlobalHotKeyOperatingMode(.disable) 禁系统热键 + 显示 overlay + 清 pressed keys
    ///   退出 (再按 Cmd+Opt / inputCaptureEnabled=false / 失焦): .enable 还原 + 隐 overlay + 清 pressed keys
    /// **不**改鼠标行为 (始终 abs 模式, usb-tablet 只支持 abs); captured 仅控制键盘抢占程度.
    public private(set) var isCaptured: Bool = false

    /// captured 时显示的右上角小标签. captureInput / releaseCapture 切显示态.
    private var captureOverlay: NSView?

    /// MTKView 必须直接是嵌入主窗口的 view, 不能放在普通 NSView 内 — 否则 AppKit 在
    /// layout 切换中触发的 viewWillMoveToWindow 会让 MTKView 内部 CVDisplayLink 失效,
    /// draw(in:) 不再被调用 → 画面卡死.
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
        // 60Hz displayLink-driven auto draw. **不**启用 enableSetNeedsDisplay — 那会让
        // resize 后 guest 静止 (无新 SURFACE_DAMAGE) 时停绘卡在最后一帧, 拖窗口改分辨率画面
        // 冻死. 60Hz 持续 present 在 Apple Silicon UMA 下 CPU < 2%.
        preferredFramesPerSecond = 60
        isPaused = false
        delegate = self
        setupCaptureOverlay()
        setupDropOverlay()
        // host → guest 文件拖放, 复用 Cmd+V 后端通路, 只接 file URLs.
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

    /// 接 SURFACE_DAMAGE 事件: 异步 schedule 一次 draw (**禁止** view.draw() 同步, 会 block
    /// main thread 冻 UI). setNeedsDisplay idempotent, AppKit 自动合并 burst 到下次 tick.
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

    /// 把 BGRA cursor data 转 NSCursor. premultipliedFirst+byteOrder32Little 在 Apple Silicon
    /// (little-endian) 下内存布局即 BGRA, 跟 wire 格式对齐.
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
            // 软件光标路径: cursor 已在 framebuffer 里, host 鼠标必须藏
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        }
    }

    // MARK: - first responder

    public override var acceptsFirstResponder: Bool { inputCaptureEnabled }
    public override func becomeFirstResponder() -> Bool {
        guard inputCaptureEnabled else { return false }
        // 重获焦点时 sync 实时 modifier 状态: 失焦期间按/松的 modifier 让 lastModifiers
        // 过期, 不 sync 则 guest 端 cmd 永远没 keyDown, cmd+s 不生效.
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

    /// 把 NSEvent 的 windowLocation 转成本 view 内的像素坐标 (左上原点, usb-tablet 期望).
    /// letterbox 修正: renderer 等比居中渲染, 黑边在上下或左右. 鼠标归一化必须按 letterbox
    /// 区域而非整 view, 否则 host 鼠标位置跟 guest 视野错位. guestFbSize 未 bind 时退化到整 view.
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

    /// view 离开 window hierarchy 时收尾:
    ///   1. 退出 captured (防 macOS 全局热键留在 disable 状态)
    ///   2. 补发所有 stuck key keyUp (防 guest 卡键)
    ///   3. 释放 first responder
    ///   4. 还原 host 鼠标 (隐了之后没 mouseExited 路径会把鼠标卡死)
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

    /// 本 view 失去 first responder 时释放 capture (避免别处操作期间系统热键仍被禁) +
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

        // 文件粘贴拦截 (Cmd+V + NSPasteboard 有 file URLs): 仅 macStyleShortcuts=true,
        // 排除 Cmd+Opt+V / Cmd+Shift+V / Cmd+Ctrl+V, 无 file URLs 走文本粘贴老路径.
        // 在 normal-key qcode 发送之前判断, 避免双发.
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

        // Cmd+Opt toggle capture. 检测: cmd+opt 同时刚按下 (cur 含两者, prev 不全含).
        let toggle: NSEvent.ModifierFlags = [.command, .option]
        let bothNow = cur.intersection(toggle) == toggle
        let bothPrev = lastModifiers.intersection(toggle) == toggle
        if bothNow && !bothPrev {
            if isCaptured {
                releaseCapture()
            } else {
                captureInput()
            }
            // toggle 路径不走正常 diff: captureInput / releaseCapture 内已 releaseAllPressedKeys
            // + reset lastModifiers = [], 后续松开 cmd/opt 时 set diff 自然干净.
            return
        }

        // Caps Lock 不在这里发 toggle (会跟 keyDown 路径的 syncCapsLockIfNeeded 重复抵消);
        // 单一 source 走 keyDown 时查 expectedGuestCaps.

        syncModifiersToGuest(cur)
    }

    /// 把 NSEvent.ModifierFlags 转成应发给 guest 的 qcode 集合. 左右修饰键靠 raw bit 区分
    /// (0x2=leftShift, 0x4=rightShift 等). macStyleShortcuts=true 时 cmd → ctrl.
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
            // macStyleShortcuts: 左右 cmd 都映射成 ctrl; 关闭时 → meta_l/meta_r (Win 键).
            // set 自动去重 (同时按 cmd + ctrl 不会重复 keyDown).
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

    /// 装 NSEvent local monitor 拦 keyUp-with-cmd (macOS 已知行为: 按住 .command 时字符键
    /// keyUp 不送 NSView → guest auto-repeat 卡键). 把 event 路由给 self.keyUp 后 return
    /// 放行. 仅本 view first responder + 捕获 + 含 cmd 才 take over (避免双 view 抢路由).
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
    /// 在丢 first responder / 离开 window / 进出 captured 时调, 避免 guest 看 keyDown 没
    /// 对应 keyUp → auto-repeat 卡键. **必须同时清 normal key + modifier** (只清前者会让
    /// cmd+tab 切走再回 guest 卡 cmd down).
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
    /// 任何退出路径都**必须**经过这里, 否则系统热键留在 disable 状态用户无法 cmd+tab 切 app.
    private func releaseCapture() {
        guard isCaptured else { return }
        releaseAllPressedKeys()
        HVMSetGlobalHotKeyOperatingMode(.enable)
        isCaptured = false
        captureOverlay?.isHidden = true
    }

    // MARK: - captured 状态视觉反馈

    /// 右上角小标签 "⌘⌥ 退出捕获". captured 时显示. 走原生 NSTextField + NSVisualEffectView.
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

    /// 把 overlay pin 到右上角. viewDidMoveToWindow 时重新约束, 防 bounds 变化后跑偏
    /// (autoresizing mask 在 MTKView 这种 layer-backed 子类有时不稳).
    private func layoutCaptureOverlay() {
        guard let bg = captureOverlay else { return }
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
    // 跟 Cmd+V 共一条后端: drag perform 时调 onFilePaste(urls) → IPC clipboard.paste-files
    // → FilePasteBridge. 这里只负责接受范围判定 + dropOverlay 视觉反馈 + URLs 抽取.

    /// drag-enter 时显示的中央高亮 hint. draggingEntered / Exited 切显隐.
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

    /// 拖入接受判定 + 视觉反馈. 接受条件 (全过): inputCaptureEnabled + macStyleShortcuts +
    /// onFilePaste 已注入 + pasteboard 含至少 1 个 file URL.
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

    /// 仅供 GUI probe 测试用: 主动切 dropOverlay 显示状态 (绕过真实 drag 流程).
    public func probeShowDropOverlay(count: Int) { showDropOverlay(count: count) }
    public func probeHideDropOverlay() { hideDropOverlay() }

    /// CapsLock 双端同步: host 与 expectedGuestCaps 不一致时给 guest 发一次 caps_lock toggle
    /// 并立即翻转 expectedGuestCaps (不等 LED_STATE 回传, 避免双重 toggle race). LED_STATE
    /// 仍会校正 expectedGuestCaps 处理乱序场景.
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
        // 不在这里 setViewSize (viewCoords 每次鼠标事件按 letterbox 实时算; 这里覆盖会错).
        // drawable 尺寸 (backing pixel) 推给上层 → RESIZE_REQUEST → dpy_set_ui_info → EDID
        // 让 guest vdagent 自动改分辨率 (guest 须装 spice-vdagent).
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        onDrawableSizeChange?(w, h)
    }

    public func draw(in view: MTKView) {
        renderer.draw(in: view)
    }
}

// MARK: - NSEvent.ModifierFlags 左右键区分扩展

/// NSEvent.ModifierFlags 公开 API 不区分左右修饰键, 但 raw bit 区分 (跟 Carbon
/// kEventKeyModifier* 同源, 来自 `Events.h` / `NSEvent.h` 私有定义, 历史稳定).
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
