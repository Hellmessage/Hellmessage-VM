// HVMView.swift
// VZVirtualMachineView 子类, 拦截 Cmd+Control 释放鼠标捕获
// 详见 docs/DISPLAY_INPUT.md "输入捕获"

import AppKit
@preconcurrency import Virtualization

public final class HVMView: VZVirtualMachineView {
    public var onReleaseCapture: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // capturesSystemKeys: 把 Cmd+Tab / Cmd+Space 等系统快捷键也送给 guest
        self.capturesSystemKeys = true
        self.automaticallyReconfiguresDisplay = false
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
