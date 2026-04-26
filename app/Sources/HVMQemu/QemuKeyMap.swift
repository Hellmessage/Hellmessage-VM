// HVMQemu/QemuKeyMap.swift
// 字符 / hvm-dbg key 标识 → QEMU qkey 名映射. 用于 sendKey 调用.
//
// QEMU qkey 名取自 qapi/qkeys.json (上游); 包括 "a"-"z", "0"-"9", "shift", "alt",
// "ctrl", "meta_l", "ret", "spc", "tab", "esc", "f1"-"f24", "backspace", 方向键
// "up"/"down"/"left"/"right" 等. 完整列表搜 qkeys.json.
//
// 设计:
//   - typeText: 一字符一字符 send. ASCII 可见字符 + 大写 + 部分符号已涵盖.
//   - pressCombo: 解析 "ctrl+c" / "cmd+space" 形式; "cmd" / "win" 别名 → meta_l.
//   - 不全, AI agent 用 unicode 输入需 guest 内 IME (与 VZ 路径同样限制).

import Foundation

public enum QemuKeyMap {

    /// hvm-dbg "press" 字符串解析: "ctrl+c" / "cmd+shift+left" → ["ctrl","c"] qkey list
    /// 不识别的 token throw .unknownKey, 调用方应返 invalidEnum.
    public enum MapError: Error, Sendable, Equatable {
        case unknownKey(String)
    }

    /// 解析 "+/-" 分隔的组合键串到 qkey list.
    /// 大小写不敏感; "cmd" / "win" → meta_l; 字符 a-z 直接, A-Z 加 shift.
    public static func parseCombo(_ combo: String) throws -> [String] {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for p in parts {
            try mapToken(p, into: &out)
        }
        return out
    }

    /// 把可见 ASCII 字符串切成"一次按键 = 一个 qkey list"序列, 给 typeText 用.
    /// 大小写敏感: 大写字母 + 部分符号需要 shift, 自动加.
    /// 不识别的字符 (例 中文) 抛 unknownKey.
    public static func tokenizeText(_ text: String) throws -> [[String]] {
        var out: [[String]] = []
        for ch in text {
            var keys: [String] = []
            try charToQKey(ch, into: &keys)
            out.append(keys)
        }
        return out
    }

    // MARK: - 内部映射

    /// "ctrl"/"shift"/"f1"/"a" 这种 token → qkey, append 到 out.
    /// 单字符 token 走 charToQKey.
    private static func mapToken(_ token: String, into out: inout [String]) throws {
        let lower = token.lowercased()
        // 修饰键 / 别名
        switch lower {
        case "ctrl", "control":   out.append("ctrl"); return
        case "shift":             out.append("shift"); return
        case "alt", "option":     out.append("alt"); return
        case "cmd", "command", "win", "meta", "super":
            out.append("meta_l"); return
        case "ret", "return", "enter":
            out.append("ret"); return
        case "esc", "escape":     out.append("esc"); return
        case "tab":               out.append("tab"); return
        case "spc", "space":      out.append("spc"); return
        case "backspace", "bksp": out.append("backspace"); return
        case "delete", "del":     out.append("delete"); return
        case "up":                out.append("up"); return
        case "down":              out.append("down"); return
        case "left":              out.append("left"); return
        case "right":             out.append("right"); return
        case "home":              out.append("home"); return
        case "end":               out.append("end"); return
        case "pgup", "pageup":    out.append("pgup"); return
        case "pgdn", "pagedown":  out.append("pgdn"); return
        case "ins", "insert":     out.append("insert"); return
        default: break
        }
        // f1-f24
        if lower.count >= 2, lower.first == "f", let n = Int(lower.dropFirst()), n >= 1 && n <= 24 {
            out.append(lower); return
        }
        // 单字符 → charToQKey
        if token.count == 1, let ch = token.first {
            try charToQKey(ch, into: &out)
            return
        }
        throw MapError.unknownKey(token)
    }

    /// 单字符 → qkey list (带 shift 时 list 含 ["shift", "<key>"]).
    private static func charToQKey(_ ch: Character, into out: inout [String]) throws {
        // 小写字母 a-z
        if let scalar = ch.unicodeScalars.first, scalar.value >= 0x61 && scalar.value <= 0x7A {
            out.append(String(ch))
            return
        }
        // 大写字母 A-Z → shift + 小写
        if let scalar = ch.unicodeScalars.first, scalar.value >= 0x41 && scalar.value <= 0x5A {
            out.append("shift")
            out.append(String(ch).lowercased())
            return
        }
        // 数字 0-9
        if let scalar = ch.unicodeScalars.first, scalar.value >= 0x30 && scalar.value <= 0x39 {
            out.append(String(ch))
            return
        }
        // 常见符号 (无 shift)
        switch ch {
        case " ":  out.append("spc"); return
        case "-":  out.append("minus"); return
        case "=":  out.append("equal"); return
        case "[":  out.append("bracket_left"); return
        case "]":  out.append("bracket_right"); return
        case ";":  out.append("semicolon"); return
        case "'":  out.append("apostrophe"); return
        case ",":  out.append("comma"); return
        case ".":  out.append("dot"); return
        case "/":  out.append("slash"); return
        case "\\": out.append("backslash"); return
        case "`":  out.append("grave_accent"); return
        case "\n": out.append("ret"); return
        case "\t": out.append("tab"); return
        default: break
        }
        // shift + 符号 (常见美式键盘 shift 层)
        let shiftMap: [Character: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
            "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "minus", "+": "equal",
            "{": "bracket_left", "}": "bracket_right",
            ":": "semicolon", "\"": "apostrophe",
            "<": "comma", ">": "dot", "?": "slash", "|": "backslash",
            "~": "grave_accent",
        ]
        if let qk = shiftMap[ch] {
            out.append("shift")
            out.append(qk)
            return
        }
        throw MapError.unknownKey(String(ch))
    }
}
