// HVMGuiProbe/ViewRegistry.swift
// gui.list / gui.click / gui.type 走 ProbeRegistry 自家 closure 注册表.
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md PR-G2 (重构).

import AppKit
import Foundation
import HVMCore

@MainActor
enum ViewRegistry {

    struct Entry: Codable {
        let identifier: String
        let label: String
        let role: String
    }

    /// 列出当前注册到 ProbeRegistry 的所有控件.
    static func list() -> [Entry] {
        ProbeRegistry.all().map { item in
            Entry(identifier: item.identifier,
                  label: item.label,
                  role: item.role)
        }
    }

    /// 触发指定 id 的 button action. 错 id / 类型不匹配返 false.
    static func click(identifier: String) -> Bool {
        guard let item = ProbeRegistry.get(identifier) else { return false }
        switch item.action {
        case .button(let action):
            action()
            return true
        case .toggle(let getter, let setter):
            setter(!getter())
            return true
        case .textField:
            return false      // textField 不能 click
        }
    }

    /// 给 textField 输文字 (覆盖现有值). 错 id / 非 text 返 false.
    static func type(identifier: String, text: String) -> Bool {
        guard let item = ProbeRegistry.get(identifier) else { return false }
        switch item.action {
        case .textField(_, let setter):
            setter(text)
            return true
        default:
            return false
        }
    }

    /// 读 textField / toggle 当前值. 不存在 / 非读取型返 nil.
    static func read(identifier: String) -> String? {
        guard let item = ProbeRegistry.get(identifier) else { return nil }
        switch item.action {
        case .textField(let getter, _):
            return getter()
        case .toggle(let getter, _):
            return getter() ? "true" : "false"
        case .button:
            return nil
        }
    }
}
