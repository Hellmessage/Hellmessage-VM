// HVMDisplay/HIDKeyMap.swift
// US 键盘布局 character → (virtual keyCode, needsShift) 映射, 加常用特殊键名 → keyCode.
//
// 参考: <Carbon/HIToolbox/Events.h> 的 kVK_* 常量. 不引 Carbon, 直接硬编码.
// 仅覆盖 ASCII 可打印字符 + 标准特殊键. 非 US 布局留给后续.

import Foundation

public enum HIDKeyMap {
    public struct CharMapping: Sendable {
        public let keyCode: UInt16
        public let shift: Bool
    }

    /// 字符 → keyCode + 是否需要 shift. nil 表示不在 US 布局可打印范围.
    public static func mapping(for char: Character) -> CharMapping? {
        if let m = charTable[char] { return m }
        return nil
    }

    /// 特殊键名 (大小写不敏感) → keyCode. 未识别返回 nil.
    public static func specialKey(_ name: String) -> UInt16? {
        specialTable[name.lowercased()]
    }

    // MARK: - 字符表 (US ANSI)

    private static let charTable: [Character: CharMapping] = {
        var t: [Character: CharMapping] = [:]
        // 字母: shift = 大写
        let lowers: [(Character, UInt16)] = [
            ("a", 0x00), ("b", 0x0B), ("c", 0x08), ("d", 0x02), ("e", 0x0E),
            ("f", 0x03), ("g", 0x05), ("h", 0x04), ("i", 0x22), ("j", 0x26),
            ("k", 0x28), ("l", 0x25), ("m", 0x2E), ("n", 0x2D), ("o", 0x1F),
            ("p", 0x23), ("q", 0x0C), ("r", 0x0F), ("s", 0x01), ("t", 0x11),
            ("u", 0x20), ("v", 0x09), ("w", 0x0D), ("x", 0x07), ("y", 0x10),
            ("z", 0x06),
        ]
        for (lo, kc) in lowers {
            t[lo] = CharMapping(keyCode: kc, shift: false)
            // 大写
            let upStr = String(lo).uppercased()
            if let up = upStr.first {
                t[up] = CharMapping(keyCode: kc, shift: true)
            }
        }

        // 数字行 + shift 后符号
        let numbers: [(Character, UInt16, Character)] = [
            ("1", 0x12, "!"), ("2", 0x13, "@"), ("3", 0x14, "#"),
            ("4", 0x15, "$"), ("5", 0x17, "%"), ("6", 0x16, "^"),
            ("7", 0x1A, "&"), ("8", 0x1C, "*"), ("9", 0x19, "("),
            ("0", 0x1D, ")"),
        ]
        for (n, kc, shifted) in numbers {
            t[n] = CharMapping(keyCode: kc, shift: false)
            t[shifted] = CharMapping(keyCode: kc, shift: true)
        }

        // 标点 (base + shifted)
        let puncts: [(Character, UInt16, Character)] = [
            ("-",  0x1B, "_"),
            ("=",  0x18, "+"),
            ("[",  0x21, "{"),
            ("]",  0x1E, "}"),
            ("\\", 0x2A, "|"),
            (";",  0x29, ":"),
            ("'",  0x27, "\""),
            (",",  0x2B, "<"),
            (".",  0x2F, ">"),
            ("/",  0x2C, "?"),
            ("`",  0x32, "~"),
        ]
        for (p, kc, shifted) in puncts {
            t[p] = CharMapping(keyCode: kc, shift: false)
            t[shifted] = CharMapping(keyCode: kc, shift: true)
        }

        // 空格 / Tab / Return / Backspace 也允许 typeText 直接使用 (\\n \\t)
        t[" "]  = CharMapping(keyCode: 0x31, shift: false)
        t["\t"] = CharMapping(keyCode: 0x30, shift: false)
        t["\n"] = CharMapping(keyCode: 0x24, shift: false)  // Return
        return t
    }()

    // MARK: - 特殊键名

    private static let specialTable: [String: UInt16] = [
        "return":     0x24,
        "enter":      0x24,
        "tab":        0x30,
        "space":      0x31,
        "backspace":  0x33,
        "delete":     0x33,        // backspace (与 forward delete 区分)
        "fwddelete":  0x75,
        "esc":        0x35,
        "escape":     0x35,
        "left":       0x7B,
        "right":      0x7C,
        "down":       0x7D,
        "up":         0x7E,
        "home":       0x73,
        "end":        0x77,
        "pageup":     0x74,
        "pagedown":   0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]
}
