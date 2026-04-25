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
            if inputSuspended { unhideCursorAggressively() }
        }
    }

    /// 用户按 Cmd+Control 主动释放捕获. 行为同 inputSuspended (屏蔽 VZ 输入 + 解隐藏光标),
    /// 区别在于"恢复时机": 用户点回 VZ view 内 (mouseDown) 即自动 false, 重新交给 VZ.
    private var captureReleased: Bool = false {
        didSet {
            guard captureReleased != oldValue else { return }
            if captureReleased { unhideCursorAggressively() }
        }
    }

    /// inputSuspended 或 captureReleased 任一为 true 时, VZ 输入全部跳过.
    private var inputBlocked: Bool { inputSuspended || captureReleased }

    private func unhideCursorAggressively() {
        // hide/unhide 是平衡计数. 不知道 VZ 调过几次, 多 unhide 几次保险.
        for _ in 0..<8 { NSCursor.unhide() }
        NSCursor.arrow.set()
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

    /// 检测 Cmd+Control combo 进入"释放"状态. 直到 mouseDown 回 VZ view 为止.
    ///
    /// 关键: 即使触发了 combo 也要 super.flagsChanged 转发. 否则 VZ 的 modifier 状态会卡在
    /// "Cmd/Ctrl 按着" — 因为 Cmd 先按下时已经走过 super (那时 combo 还不成立),
    /// 而 combo 命中那一刻拦掉 super, 后续松键又被 inputBlocked 屏蔽 → VZ 永远收不到松开,
    /// 重捕获后所有按键都被当成 Cmd+xxx 快捷键, guest 看不到字符. 让 VZ 始终有准确的
    /// modifier 镜像即可, 那期间 keyDown 反正被屏蔽不会有副作用.
    public override func flagsChanged(with event: NSEvent) {
        if inputSuspended { return }  // 弹窗期连 modifier 也不给, 行为对齐其他鼠标事件
        let combo: NSEvent.ModifierFlags = [.command, .control]
        if event.modifierFlags.intersection(combo) == combo {
            captureReleased = true
            onReleaseCapture?()
        }
        super.flagsChanged(with: event)
    }

    // MARK: - 输入屏蔽期: inputSuspended (弹窗) 或 captureReleased (用户主动) 任一生效都跳过 VZ super 调用

    public override func keyDown(with event: NSEvent) {
        if inputBlocked { return }
        super.keyDown(with: event)
    }
    public override func keyUp(with event: NSEvent) {
        if inputBlocked { return }
        super.keyUp(with: event)
    }

    public override func mouseEntered(with event: NSEvent) {
        if inputBlocked { return }
        super.mouseEntered(with: event)
    }
    public override func mouseExited(with event: NSEvent) {
        if inputBlocked { return }
        super.mouseExited(with: event)
    }
    public override func mouseMoved(with event: NSEvent) {
        if inputBlocked { return }
        super.mouseMoved(with: event)
    }
    public override func mouseDown(with event: NSEvent) {
        // 弹窗期 dialog 在前, 不重捕获 (恢复要等 dialog 关闭)
        if inputSuspended { return }
        // 用户主动释放后点回 view 内: 取消释放, 这一击照常给 VZ.
        // 不动 first responder, 始终是自己, 避免 VZ 内部状态错乱.
        if captureReleased {
            captureReleased = false
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    public override func mouseUp(with event: NSEvent) {
        if inputBlocked { return }
        super.mouseUp(with: event)
    }
    public override func mouseDragged(with event: NSEvent) {
        if inputBlocked { return }
        super.mouseDragged(with: event)
    }
    public override func rightMouseDown(with event: NSEvent) {
        if inputBlocked { return }
        super.rightMouseDown(with: event)
    }
    public override func rightMouseUp(with event: NSEvent) {
        if inputBlocked { return }
        super.rightMouseUp(with: event)
    }
    public override func rightMouseDragged(with event: NSEvent) {
        if inputBlocked { return }
        super.rightMouseDragged(with: event)
    }
    public override func otherMouseDown(with event: NSEvent) {
        if inputBlocked { return }
        super.otherMouseDown(with: event)
    }
    public override func otherMouseUp(with event: NSEvent) {
        if inputBlocked { return }
        super.otherMouseUp(with: event)
    }
    public override func otherMouseDragged(with event: NSEvent) {
        if inputBlocked { return }
        super.otherMouseDragged(with: event)
    }
    public override func scrollWheel(with event: NSEvent) {
        if inputBlocked { return }
        super.scrollWheel(with: event)
    }
    public override func cursorUpdate(with event: NSEvent) {
        if inputBlocked {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }
}
