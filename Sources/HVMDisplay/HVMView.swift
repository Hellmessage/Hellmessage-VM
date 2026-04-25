// HVMView.swift
// VZVirtualMachineView 子类, 拦截 Cmd+Control 释放鼠标捕获
// 详见 docs/DISPLAY_INPUT.md "输入捕获"

import AppKit
@preconcurrency import Virtualization

public final class HVMView: VZVirtualMachineView {
    public var onReleaseCapture: (() -> Void)?
    /// view 进入某个 window 时触发 (viewDidMoveToWindow). 用于延迟绑定 VZVirtualMachine —
    /// Metal drawable 仅在 view 已 attach 到 window + virtualMachine 已 set 时创建.
    public var onEnteredWindow: (() -> Void)?

    /// 当主窗口出现 modal-style overlay 弹窗时, 把 VZ view 的鼠标/键盘输入"挂起":
    /// - 所有 mouse* / scrollWheel / flagsChanged / cursorUpdate 跳过 super → guest 不再收到 host 输入
    /// - 同时把 VZ 在 mouseEntered/Moved 里累计的 NSCursor.hide() 抵消, 否则光标已经隐藏在弹窗弹起前
    /// 注意: VZVirtualMachineView 用全局 NSCursor.hide(), 不是 cursor rect; 仅用 cursor rect 压不过.
    public var inputSuspended: Bool = false {
        didSet {
            guard inputSuspended != oldValue else { return }
            if inputSuspended {
                // hide/unhide 是平衡计数. 不知道 VZ 调过几次, 多 unhide 几次保险.
                for _ in 0..<8 { NSCursor.unhide() }
                NSCursor.arrow.set()
            }
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil {
            onEnteredWindow?()
        }
    }

    private func configure() {
        // capturesSystemKeys: 把 Cmd+Tab / Cmd+Space 等系统快捷键也送给 guest
        self.capturesSystemKeys = true
        // false: VZ view 按 aspect fit 拉伸 framebuffer 到 view 尺寸. 字大且画面填满,
        // 缺点是 guest 内分辨率始终是 initial scanout, 装完桌面 resize 也不跟随.
        // true 配合 X/Wayland guest 才有意义, 但 installer / fbcon 不响应 resize 会留大片黑.
        // 当前阶段 (M2) 先优先 installer 体验.
        self.automaticallyReconfiguresDisplay = false
        // 注意: 不碰 self.wantsLayer / self.layer.contentsGravity
        // VZVirtualMachineView 内部自己管理 CAMetalLayer, 外部设置会让 Metal drawable 失效 → 黑屏
    }

    /// 拦截修饰键变化. 用户同时按下 Cmd + Control 时释放捕获
    public override func flagsChanged(with event: NSEvent) {
        if inputSuspended { return }
        let combo: NSEvent.ModifierFlags = [.command, .control]
        let masked = event.modifierFlags.intersection(combo)
        if masked == combo {
            // 释放 first responder, 后续 keyboard 事件不再给 VZ
            window?.makeFirstResponder(nil)
            onReleaseCapture?()
            return
        }
        super.flagsChanged(with: event)
    }

    // MARK: - 输入挂起期: 屏蔽全部 VZ 鼠标 super 调用

    public override func mouseEntered(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseEntered(with: event)
    }
    public override func mouseExited(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseExited(with: event)
    }
    public override func mouseMoved(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseMoved(with: event)
    }
    public override func mouseDown(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseDown(with: event)
    }
    public override func mouseUp(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseUp(with: event)
    }
    public override func mouseDragged(with event: NSEvent) {
        if inputSuspended { return }
        super.mouseDragged(with: event)
    }
    public override func rightMouseDown(with event: NSEvent) {
        if inputSuspended { return }
        super.rightMouseDown(with: event)
    }
    public override func rightMouseUp(with event: NSEvent) {
        if inputSuspended { return }
        super.rightMouseUp(with: event)
    }
    public override func rightMouseDragged(with event: NSEvent) {
        if inputSuspended { return }
        super.rightMouseDragged(with: event)
    }
    public override func otherMouseDown(with event: NSEvent) {
        if inputSuspended { return }
        super.otherMouseDown(with: event)
    }
    public override func otherMouseUp(with event: NSEvent) {
        if inputSuspended { return }
        super.otherMouseUp(with: event)
    }
    public override func otherMouseDragged(with event: NSEvent) {
        if inputSuspended { return }
        super.otherMouseDragged(with: event)
    }
    public override func scrollWheel(with event: NSEvent) {
        if inputSuspended { return }
        super.scrollWheel(with: event)
    }
    public override func cursorUpdate(with event: NSEvent) {
        if inputSuspended {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}
