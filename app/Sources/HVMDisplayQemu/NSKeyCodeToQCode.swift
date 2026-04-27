// NSKeyCodeToQCode.swift
//
// macOS NSEvent.keyCode → QEMU QMP `qcode` 字符串 静态映射.
//
// QEMU 端的 qcode 名字定义在 qapi/ui.json 的 `QKeyCode` enum (上游标准, 不需自定义).
// 客户端通过 QMP `input-send-event` 命令发送, payload 形如:
//   { "type": "key", "data": { "down": <bool>,
//                                "key": { "type": "qcode", "data": "<qcode>" } } }
//
// macOS keyCode 来自 Carbon HIToolbox `Events.h` 的 kVK_* 常量, 数值固定.

import Foundation

/// macOS keyCode → QEMU qcode 字符串映射器.
public enum HVMQCode {

    /// 给定 NSEvent.keyCode 返回 QEMU qcode 字符串. 未识别返回 nil.
    public static func qcode(forKeyCode keyCode: UInt16) -> String? {
        return mapping[keyCode]
    }

    /// 主映射表 (US ANSI 键盘布局; 修饰键 / 功能键 / 小键盘全覆盖).
    /// 如发现 guest 内某键无响应, 优先确认: (a) NSEvent 实际 keyCode 是否在表里;
    /// (b) QEMU 是否在 InputKeyEvent 字段加了新 qcode.
    private static let mapping: [UInt16: String] = [
        // ANSI 字母 (kVK_ANSI_*)
        0x00: "a",  0x0B: "b",  0x08: "c",  0x02: "d",  0x0E: "e",
        0x03: "f",  0x05: "g",  0x04: "h",  0x22: "i",  0x26: "j",
        0x28: "k",  0x25: "l",  0x2E: "m",  0x2D: "n",  0x1F: "o",
        0x23: "p",  0x0C: "q",  0x0F: "r",  0x01: "s",  0x11: "t",
        0x20: "u",  0x09: "v",  0x0D: "w",  0x07: "x",  0x10: "y",
        0x06: "z",

        // 数字行
        0x12: "1",  0x13: "2",  0x14: "3",  0x15: "4",  0x17: "5",
        0x16: "6",  0x1A: "7",  0x1C: "8",  0x19: "9",  0x1D: "0",

        // 符号
        0x1B: "minus",        0x18: "equal",
        0x21: "bracket_left", 0x1E: "bracket_right",
        0x29: "semicolon",    0x27: "apostrophe",
        0x32: "grave_accent",
        0x2A: "backslash",
        0x2B: "comma",        0x2F: "dot",      0x2C: "slash",

        // 编辑 / 控制
        0x24: "ret",          0x30: "tab",      0x31: "spc",
        0x33: "backspace",    0x35: "esc",      0x39: "caps_lock",
        0x75: "delete",       0x72: "insert",   0x73: "home",
        0x77: "end",          0x74: "pgup",     0x79: "pgdn",

        // 方向
        0x7B: "left",  0x7C: "right",  0x7D: "down",  0x7E: "up",

        // 修饰键 (左/右独立)
        0x38: "shift",      0x3C: "shift_r",
        0x3B: "ctrl",       0x3E: "ctrl_r",
        0x3A: "alt",        0x3D: "alt_r",
        0x37: "meta_l",     0x36: "meta_r",

        // 功能键 F1-F15 (kVK_F* 映射)
        0x7A: "f1",   0x78: "f2",   0x63: "f3",   0x76: "f4",
        0x60: "f5",   0x61: "f6",   0x62: "f7",   0x64: "f8",
        0x65: "f9",   0x6D: "f10",  0x67: "f11",  0x6F: "f12",
        0x69: "f13",  0x6B: "f14",  0x71: "f15",

        // 小键盘 (kVK_ANSI_Keypad*)
        0x52: "kp_0",  0x53: "kp_1",  0x54: "kp_2",  0x55: "kp_3",
        0x56: "kp_4",  0x57: "kp_5",  0x58: "kp_6",  0x59: "kp_7",
        0x5B: "kp_8",  0x5C: "kp_9",
        0x41: "kp_decimal",
        0x4B: "kp_divide",
        0x43: "kp_multiply",
        0x4E: "kp_subtract",
        0x45: "kp_add",
        0x4C: "kp_enter",
        0x51: "kp_equals",

        // PC 兼容键 (现代 Apple 键盘罕见但保留)
        0x47: "num_lock",
    ]
}
