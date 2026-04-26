// HVMDisplay/KeyboardEmulator.swift
// 把 hvm-dbg key 的 "text" / "press" 翻成 NSEvent 序列, 通过 HVMView.inject 进 VZ.
//
// 不走 CGEvent — 那要辅助功能权限 (CLAUDE.md 明确禁止 osascript 路线).
// 走 NSEvent.keyEvent + view.keyDown super 路径, VZVirtualMachineView 内部
// 把 NSEvent 翻译成 USB HID Usage 通过 VZUSBKeyboard 发给 guest.

import AppKit
import Foundation
import HVMCore

@MainActor
public enum KeyboardEmulator {
    /// 注入字符串文本. 不识别的字符抛 .config(.invalidEnum).
    /// 每个字符发 (shift down + keyDown + keyUp + shift up) 或 (keyDown + keyUp).
    public static func typeText(_ text: String, into view: HVMView) throws {
        for ch in text {
            guard let m = HIDKeyMap.mapping(for: ch) else {
                throw HVMError.config(.invalidEnum(
                    field: "key.text",
                    raw: String(ch),
                    allowed: ["US ASCII printable + \\n \\t"]
                ))
            }
            try injectChar(keyCode: m.keyCode, shift: m.shift,
                           characters: String(ch), into: view)
        }
    }

    /// 注入按键序列. seq 由空格分隔的多组动作组成, 每组 mod1+mod2+key 或单独的 key.
    /// 例:  "cmd+t"  /  "Return"  /  "cmd+t cmd+w"  /  "shift+a"
    public static func pressKeys(_ seq: String, into view: HVMView) throws {
        let actions = seq.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for action in actions {
            try press(combo: action, into: view)
        }
    }

    // MARK: - 内部

    private static func press(combo: String, into view: HVMView) throws {
        let parts = combo.split(separator: "+").map(String.init)
        guard let last = parts.last else {
            throw HVMError.config(.invalidEnum(field: "key.press", raw: combo, allowed: ["mod+key"]))
        }
        let mods = parts.dropLast()

        // 解析修饰符
        var modFlags: NSEvent.ModifierFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command":  modFlags.insert(.command)
            case "ctrl", "control": modFlags.insert(.control)
            case "shift":           modFlags.insert(.shift)
            case "alt", "opt", "option": modFlags.insert(.option)
            case "fn", "function":  modFlags.insert(.function)
            default:
                throw HVMError.config(.invalidEnum(field: "key.press.modifier", raw: m,
                                                   allowed: ["cmd", "ctrl", "shift", "alt", "fn"]))
            }
        }

        // 解析主键: 先看特殊键名, 再看单字符
        let keyCode: UInt16
        let chars: String
        let shiftFromChar: Bool
        if let kc = HIDKeyMap.specialKey(last) {
            keyCode = kc
            chars = ""              // 特殊键不传字符 (VZ 走 keyCode 路径)
            shiftFromChar = false
        } else if last.count == 1, let m = HIDKeyMap.mapping(for: Character(last)) {
            keyCode = m.keyCode
            chars = last
            shiftFromChar = m.shift
        } else {
            throw HVMError.config(.invalidEnum(field: "key.press.key", raw: last,
                                               allowed: ["单字符 / Return / Tab / F1-F12 / Left/Right/.."]))
        }

        if shiftFromChar { modFlags.insert(.shift) }

        // 1. 修饰键 down (按 cmd ctrl shift opt fn 顺序)
        var partial: NSEvent.ModifierFlags = []
        for one in [NSEvent.ModifierFlags.command, .control, .shift, .option, .function] {
            if modFlags.contains(one) {
                partial.insert(one)
                try emitFlagsChanged(flags: partial, into: view)
            }
        }

        // 2. keyDown + keyUp 主键 (modifierFlags 带上完整 mod)
        try emitKey(.keyDown, keyCode: keyCode, characters: chars, modifierFlags: modFlags, into: view)
        try emitKey(.keyUp,   keyCode: keyCode, characters: chars, modifierFlags: modFlags, into: view)

        // 3. 修饰键 up (按相反顺序释放)
        for one in [NSEvent.ModifierFlags.function, .option, .shift, .control, .command] {
            if partial.contains(one) {
                partial.remove(one)
                try emitFlagsChanged(flags: partial, into: view)
            }
        }
    }

    private static func injectChar(keyCode: UInt16, shift: Bool,
                                    characters: String, into view: HVMView) throws {
        var mods: NSEvent.ModifierFlags = []
        if shift {
            mods.insert(.shift)
            try emitFlagsChanged(flags: mods, into: view)
        }
        try emitKey(.keyDown, keyCode: keyCode, characters: characters, modifierFlags: mods, into: view)
        try emitKey(.keyUp,   keyCode: keyCode, characters: characters, modifierFlags: mods, into: view)
        if shift {
            mods.remove(.shift)
            try emitFlagsChanged(flags: mods, into: view)
        }
    }

    private static func emitKey(_ type: NSEvent.EventType,
                                 keyCode: UInt16,
                                 characters: String,
                                 modifierFlags: NSEvent.ModifierFlags,
                                 into view: HVMView) throws {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw HVMError.backend(.vzInternal(description: "NSEvent.keyEvent 构造失败 keyCode=\(keyCode)"))
        }
        view.inject(event: event)
    }

    /// 合成 flagsChanged 事件喂给 view. 实测 VZ 只在 keyDown 上看 modifierFlags 不够 — 它内部
    /// 跟踪 modifier state 是基于 flagsChanged 序列, 不发 flagsChanged 时 shift 在 guest 永远是 off,
    /// `|`/`!`/`@`/大写字母这类 shift 字符全部落小写 → `\`/`1`/`2`/小写.
    /// NSEvent.keyEvent 不接受 .flagsChanged 类型, 走 CGEvent 转一道.
    /// 不需要权限: 没 CGEventPost, 只是把合成 NSEvent 喂给 view 的 super.flagsChanged dispatch.
    private static func emitFlagsChanged(flags: NSEvent.ModifierFlags, into view: HVMView) throws {
        guard let cge = CGEvent(source: nil) else {
            throw HVMError.backend(.vzInternal(description: "CGEvent 合成失败"))
        }
        cge.type = .flagsChanged
        var cgFlags: CGEventFlags = []
        if flags.contains(.shift)    { cgFlags.insert(.maskShift) }
        if flags.contains(.command)  { cgFlags.insert(.maskCommand) }
        if flags.contains(.control)  { cgFlags.insert(.maskControl) }
        if flags.contains(.option)   { cgFlags.insert(.maskAlternate) }
        if flags.contains(.function) { cgFlags.insert(.maskSecondaryFn) }
        cge.flags = cgFlags
        // flagsChanged 事件按惯例带"哪个 modifier 在变化"的 keyCode. 选 shift 做代表 (0x38 = left shift),
        // 大部分被 shift 的字符走这条; 其他 modifier 用同样路径但传不同 keyCode 也成立.
        cge.setIntegerValueField(.keyboardEventKeycode, value: 0x38)
        if let nse = NSEvent(cgEvent: cge) {
            view.inject(event: nse)
        }
    }
}
