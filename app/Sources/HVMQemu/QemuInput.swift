// HVMQemu/QemuInput.swift
// 高层输入注入: 把 hvm-dbg 的 args.text / args.press / mouse op 翻译成 QmpClient 调用.
// 与 VZ 端 KeyboardEmulator + MouseEmulator 形态对齐.

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

    /// 按组合键: "ctrl+c" / "cmd+space" 等. 一次按下后释放.
    public static func pressCombo(_ combo: String, via client: QmpClient) async throws {
        let qkeys: [String]
        do {
            qkeys = try QemuKeyMap.parseCombo(combo)
        } catch let QemuKeyMap.MapError.unknownKey(k) {
            throw InputError.unknownKey(k)
        }
        try await client.sendKey(qkeys, holdTimeMs: 100)
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

    /// 鼠标点击: 移动 → 按下 → 释放. button: "left"/"right"/"middle".
    public static func mouseClick(
        x: Int, y: Int,
        button: String = "left",
        guestSize: CGSize,
        via client: QmpClient
    ) async throws {
        guard ["left", "right", "middle"].contains(button) else {
            throw InputError.unsupportedButton(button)
        }
        var events = absMoveEvents(x: x, y: y, guestSize: guestSize)
        events.append(["type": "btn", "data": ["button": button, "down": true]])
        events.append(["type": "btn", "data": ["button": button, "down": false]])
        try await client.inputSendEvent(events: events)
    }

    /// 双击: 两次 click 中间留点儿间隔
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
