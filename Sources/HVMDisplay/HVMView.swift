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
        // 窗口 resize 时自动通知 guest 调 framebuffer 分辨率.
        // 注意: 仅对响应 virtio-gpu resize 事件的 guest 生效 (X/Wayland 桌面).
        // Linux text-mode fbcon 不响应, installer 阶段看到的是固定分辨率画面.
        self.automaticallyReconfiguresDisplay = true
        // 注意: 不碰 self.wantsLayer / self.layer.contentsGravity
        // VZVirtualMachineView 内部自己管理 CAMetalLayer, 外部设置会让 Metal drawable 失效 → 黑屏
    }

    /// 拦截修饰键变化. 用户同时按下 Cmd + Control 时释放捕获
    public override func flagsChanged(with event: NSEvent) {
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
}
