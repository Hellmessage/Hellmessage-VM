// CGSPrivate.swift
//
// Skylight (CoreGraphics 私有) API 声明. 用 @_silgen_name 直接 link, 不引 header.
//
// 用途: captured 模式 (FramebufferHostView.captureInput) 禁用 macOS 全局热键,
// 让 Cmd+Tab / Cmd+Space / Mission Control 等系统快捷键也能送进 guest VM,
// 而不是被 macOS 拦走. 跟 UTM 的 VMMetalView.captureMouse / releaseMouse 同款做法.
//
// 注意:
//   1. 私有 API, 历史上 macOS 14+ 仍可用 (UTM 长期依赖, 至今未坏); 未来若 Apple
//      改了 ABI 编译会断, 写明 fallback 路径 (调用方 catch nil 静默放弃).
//   2. 不签 App Sandbox; 这函数在 sandbox 下 silently no-op.
//   3. 释放捕获时**必须**再调一次 .enable 还原, 否则用户切到别 App 后系统级 cmd+tab
//      也失效, 体验灾难. 走 deinit + viewWillMove(toWindow:nil) 双保险.

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
