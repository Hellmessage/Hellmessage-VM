// HVMDisplay/MouseEmulator.swift
// 把 hvm-dbg mouse 的 op + 坐标翻成 NSEvent 序列, 通过 HVMView.inject 进 VZ.
// 和 KeyboardEmulator 同样不依赖辅助功能权限.
//
// 坐标系: 调用方传 guest 像素坐标 (左上角 0,0). 此处:
//   1. 按 view.bounds / guest framebuffer 比例线性缩放 → view 内点坐标 (AppKit 左下原点)
//   2. view.convert(_:to: nil) → window 坐标
//   3. NSEvent.mouseEvent(location:) 用 window 坐标
//
// 限制: 假设 view 渲染 guest framebuffer 是 stretch-fit (与 ConfigBuilder 当前配置一致).
// 若改成 aspect-fit + letterbox, 这里要补居中偏移. 后续按需要再加.

import AppKit
import Foundation
import HVMCore

@MainActor
public enum MouseEmulator {
    public enum Button: String, Sendable {
        case left, right, middle
    }

    /// 单点移动, 不按键
    public static func move(to guestPoint: CGPoint, guestSize: CGSize, into view: HVMView) throws {
        let win = try toWindow(guestPoint: guestPoint, guestSize: guestSize, view: view)
        try emit(.mouseMoved, at: win, button: .left, clickCount: 0, into: view)
    }

    /// 单击 (按 → 抬). clickCount=1.
    public static func click(at guestPoint: CGPoint, guestSize: CGSize,
                              button: Button, into view: HVMView) throws {
        let win = try toWindow(guestPoint: guestPoint, guestSize: guestSize, view: view)
        try emit(downType(button), at: win, button: button, clickCount: 1, into: view)
        try emit(upType(button),   at: win, button: button, clickCount: 1, into: view)
    }

    /// 双击. 第一次 clickCount=1, 第二次 clickCount=2.
    public static func doubleClick(at guestPoint: CGPoint, guestSize: CGSize,
                                    button: Button, into view: HVMView) throws {
        let win = try toWindow(guestPoint: guestPoint, guestSize: guestSize, view: view)
        try emit(downType(button), at: win, button: button, clickCount: 1, into: view)
        try emit(upType(button),   at: win, button: button, clickCount: 1, into: view)
        try emit(downType(button), at: win, button: button, clickCount: 2, into: view)
        try emit(upType(button),   at: win, button: button, clickCount: 2, into: view)
    }

    /// 拖拽: 在 from 处 mouseDown, 移动 (mouseDragged) 到 to, 抬起.
    public static func drag(from a: CGPoint, to b: CGPoint, guestSize: CGSize,
                             button: Button, into view: HVMView) throws {
        let winA = try toWindow(guestPoint: a, guestSize: guestSize, view: view)
        let winB = try toWindow(guestPoint: b, guestSize: guestSize, view: view)
        try emit(downType(button),    at: winA, button: button, clickCount: 1, into: view)
        try emit(draggedType(button), at: winB, button: button, clickCount: 1, into: view)
        try emit(upType(button),      at: winB, button: button, clickCount: 1, into: view)
    }

    // MARK: - 内部

    private static func toWindow(guestPoint: CGPoint, guestSize: CGSize, view: HVMView) throws -> NSPoint {
        guard view.window != nil else {
            throw HVMError.backend(.vzInternal(description: "view 未挂在 window 上, 无法注入鼠标"))
        }
        guard guestSize.width > 0, guestSize.height > 0 else {
            throw HVMError.config(.invalidEnum(field: "mouse.guestSize", raw: "\(guestSize)",
                                                allowed: ["正数"]))
        }
        let bounds = view.bounds
        let sx = bounds.width  / guestSize.width
        let sy = bounds.height / guestSize.height
        // AppKit y 翻转: guest y=0 对应 view 顶部, view y=bounds.height
        let viewPoint = NSPoint(
            x: guestPoint.x * sx,
            y: bounds.height - guestPoint.y * sy
        )
        return view.convert(viewPoint, to: nil)
    }

    private static func downType(_ b: Button) -> NSEvent.EventType {
        switch b {
        case .left:   return .leftMouseDown
        case .right:  return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }
    private static func upType(_ b: Button) -> NSEvent.EventType {
        switch b {
        case .left:   return .leftMouseUp
        case .right:  return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
    private static func draggedType(_ b: Button) -> NSEvent.EventType {
        switch b {
        case .left:   return .leftMouseDragged
        case .right:  return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    private static func emit(_ type: NSEvent.EventType, at point: NSPoint, button: Button,
                              clickCount: Int, into view: HVMView) throws {
        let buttonNumber: Int
        switch button {
        case .left:   buttonNumber = 0
        case .right:  buttonNumber = 1
        case .middle: buttonNumber = 2
        }
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .mouseMoved ? 0 : 1
        ) else {
            throw HVMError.backend(.vzInternal(description: "NSEvent.mouseEvent 构造失败 type=\(type) btn=\(buttonNumber)"))
        }
        view.inject(event: event)
    }
}
