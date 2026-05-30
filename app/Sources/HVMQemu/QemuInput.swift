// HVMQemu/QemuInput.swift
// 高层输入注入: 把 hvm-dbg 的 text / press / mouse op 翻译成 QmpClient 调用.

import Foundation
import CoreGraphics

public enum QemuInput {

    public enum InputError: Error, Sendable, Equatable {
        case unknownKey(String)
        case invalidPoint(reason: String)
        case unsupportedButton(String)
    }

    /// 输入文本: 一字符一字符 send-key, 间隔 50ms 给 guest 缓冲.
    /// 不识别字符 (中文等) throw .unknownKey, 上层应转 invalidEnum.
    public static func typeText(_ text: String, via client: QmpClient) async throws {
        let tokens: [[String]]
        do {
            tokens = try QemuKeyMap.tokenizeText(text)
        } catch let QemuKeyMap.MapError.unknownKey(k) {
            throw InputError.unknownKey(k)
        }
        for keys in tokens {
            try await client.sendKey(keys, holdTimeMs: 50)
        }
    }

    /// 按组合键: "ctrl+c" / "cmd+space" 等. 显式分帧:
    ///   modifier down → 25ms → key down → 60ms → key up → modifier up (反序).
    ///
    /// **关键**: USB HID 模式下 modifier byte 必须先置位再发 key code, 不能同帧 (否则 Windows
    /// HID stack 接不全, Win+R / Ctrl+Shift+Esc 等系统快捷键失效). 单 key 走 send-key 兜底.
    public static func pressCombo(_ combo: String, via client: QmpClient) async throws {
        let qkeys: [String]
        do {
            qkeys = try QemuKeyMap.parseCombo(combo)
        } catch let QemuKeyMap.MapError.unknownKey(k) {
            throw InputError.unknownKey(k)
        }
        // 单键 (无 modifier 组合) 直接 send-key, 不走分帧路径
        if qkeys.count <= 1 {
            try await client.sendKey(qkeys, holdTimeMs: 100)
            return
        }
        // qkeys 末位是 main key, 前面全是 modifier (parseCombo 按 token 顺序保留 modifier 在前)
        let modifiers = Array(qkeys.dropLast())
        let mainKey = qkeys.last!
        // 1) modifier down (一次 input-send-event 多个 key down event, 全都 down)
        let modDownEvents: [[String: Any]] = modifiers.map { qk in
            ["type": "key", "data": ["down": true, "key": ["type": "qcode", "data": qk]]]
        }
        try await client.inputSendEvent(events: modDownEvents)
        try await Task.sleep(nanoseconds: 25_000_000)
        // 2) main key down → 60ms → key up
        try await client.inputSendEvent(events: [
            ["type": "key", "data": ["down": true, "key": ["type": "qcode", "data": mainKey]]],
        ])
        try await Task.sleep(nanoseconds: 60_000_000)
        try await client.inputSendEvent(events: [
            ["type": "key", "data": ["down": false, "key": ["type": "qcode", "data": mainKey]]],
        ])
        try await Task.sleep(nanoseconds: 25_000_000)
        // 3) modifier up (反序 release)
        let modUpEvents: [[String: Any]] = modifiers.reversed().map { qk in
            ["type": "key", "data": ["down": false, "key": ["type": "qcode", "data": qk]]]
        }
        try await client.inputSendEvent(events: modUpEvents)
    }

    /// 鼠标移动: guest 像素坐标 → input-send-event 0..32767 abs 范围.
    public static func mouseMove(
        x: Int, y: Int,
        guestSize: CGSize,
        via client: QmpClient
    ) async throws {
        let events = absMoveEvents(x: x, y: y, guestSize: guestSize)
        try await client.inputSendEvent(events: events)
    }

    /// 鼠标点击: 移动 → 按下 → 等 80ms → 释放. button: "left"/"right"/"middle".
    /// **关键**: down 跟 up 必须分开 input-send-event 发 + 中间 sleep, 否则 Windows HID stack
    /// 接成 "hover/short tap" 收不到 click. 80ms 是实测 Win11 + ARM viogpudo 稳定值 (50ms 偶尔失败).
    public static func mouseClick(
        x: Int, y: Int,
        button: String = "left",
        guestSize: CGSize,
        via client: QmpClient
    ) async throws {
        guard ["left", "right", "middle"].contains(button) else {
            throw InputError.unsupportedButton(button)
        }
        // 1) move + button down 合一帧 (减少 RTT)
        var downEvents = absMoveEvents(x: x, y: y, guestSize: guestSize)
        downEvents.append(["type": "btn", "data": ["button": button, "down": true]])
        try await client.inputSendEvent(events: downEvents)
        // 2) 等 USB HID + Windows DWM 注册 down
        try await Task.sleep(nanoseconds: 80_000_000)
        // 3) button up 单独一帧
        try await client.inputSendEvent(events: [
            ["type": "btn", "data": ["button": button, "down": false]]
        ])
    }

    /// 双击: 两次 click 中间留点儿间隔 (跟 click 内部 down→80ms→up 间隔叠加, 总 ~240ms 完成)
    public static func mouseDoubleClick(
        x: Int, y: Int,
        button: String = "left",
        guestSize: CGSize,
        via client: QmpClient
    ) async throws {
        try await mouseClick(x: x, y: y, button: button, guestSize: guestSize, via: client)
        try await Task.sleep(nanoseconds: 80_000_000)
        try await mouseClick(x: x, y: y, button: button, guestSize: guestSize, via: client)
    }

    /// 拖拽: move 到起点 → 按下 → 8 步线性插值 move → 释放, 每帧 20ms.
    /// guest GUI 一般要求"按下后有移动事件"才认 drag, 中间步必须有.
    public static func mouseDrag(
        fromX: Int, fromY: Int,
        toX: Int, toY: Int,
        button: String = "left",
        guestSize: CGSize,
        via client: QmpClient
    ) async throws {
        guard ["left", "right", "middle"].contains(button) else {
            throw InputError.unsupportedButton(button)
        }

        // 1. move 到起点 + 按下 合一帧
        var startEvents = absMoveEvents(x: fromX, y: fromY, guestSize: guestSize)
        startEvents.append(["type": "btn", "data": ["button": button, "down": true]])
        try await client.inputSendEvent(events: startEvents)
        try await Task.sleep(nanoseconds: 20_000_000)

        // 2. 中间线性插值 (8 个内部点 + 终点, 不含起点)
        let steps = 8
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = fromX + Int((Double(toX - fromX) * t).rounded())
            let y = fromY + Int((Double(toY - fromY) * t).rounded())
            try await client.inputSendEvent(events: absMoveEvents(x: x, y: y, guestSize: guestSize))
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // 3. 终点释放
        try await client.inputSendEvent(events: [
            ["type": "btn", "data": ["button": button, "down": false]]
        ])
    }

    // MARK: - 内部

    /// QEMU input-send-event abs 坐标范围是 0..32767 (规约值, 与像素无关).
    /// 线性映射 guest 像素 → abs.
    private static func absMoveEvents(x: Int, y: Int, guestSize: CGSize) -> [[String: Any]] {
        let gw = max(1, Int(guestSize.width))
        let gh = max(1, Int(guestSize.height))
        let abs_x = min(32767, max(0, x * 32767 / gw))
        let abs_y = min(32767, max(0, y * 32767 / gh))
        return [
            ["type": "abs", "data": ["axis": "x", "value": abs_x]],
            ["type": "abs", "data": ["axis": "y", "value": abs_y]],
        ]
    }
}
