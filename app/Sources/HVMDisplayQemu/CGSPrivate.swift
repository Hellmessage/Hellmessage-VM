// CGSPrivate.swift
//
// Skylight (CoreGraphics 私有) API 声明. 用 @_silgen_name 直接 link, 不引 header.
// 用途: captured 模式 (FramebufferHostView.captureInput) 禁用 macOS 全局热键,
// 让 Cmd+Tab / Cmd+Space / Mission Control 等系统快捷键也送进 guest.
//
// 硬约束: 释放捕获时**必须**再调一次 .enable 还原, 否则用户切到别 App 后系统级
// cmd+tab 也失效. 走 deinit + viewWillMove(toWindow:nil) 双保险. 私有 API 在
// sandbox / 未来 macOS 可能 no-op, 失败 silent.

import Foundation
import CoreGraphics

// MARK: - Skylight 私有 API

/// 全局快捷键操作模式. 跟 UTM CGSPrivate.h 同一组定义.
public enum CGSGlobalHotKeyOperatingMode: Int32 {
    /// 启用 (默认): macOS 处理 cmd+tab / cmd+space / 截图等系统级快捷键.
    case enable  = 0
    /// 禁用: 上述快捷键不被 macOS 处理, 透传到 first responder (我们的 view) → guest.
    case disable = 1
}

@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetGlobalHotKeyOperatingMode")
private func _CGSSetGlobalHotKeyOperatingMode(_ cid: Int32, _ mode: Int32) -> Int32

/// 切系统全局热键模式. 失败 silent (私有 API 在 sandbox / 未来 macOS 可能 no-op).
@discardableResult
public func HVMSetGlobalHotKeyOperatingMode(_ mode: CGSGlobalHotKeyOperatingMode) -> Bool {
    let cid = _CGSMainConnectionID()
    let rc = _CGSSetGlobalHotKeyOperatingMode(cid, mode.rawValue)
    return rc == 0
}
