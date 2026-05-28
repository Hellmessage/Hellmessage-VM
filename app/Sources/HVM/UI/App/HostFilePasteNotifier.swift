// HostFilePasteNotifier.swift
//
// host → guest 文件粘贴成功后的原生系统通知.
// 设计稿 docs/v3/HOST_FILE_PASTE.md §5.5.
//
// 走 UNUserNotificationCenter (macOS 10.14+ 标准). 首次使用时 requestAuthorization
// 弹原生系统提示框, 用户授权后续才显示通知. 拒绝授权 → silently 不通知 (用户能在
// 系统设置里改; ErrorPresenter 仍能显示 fallback).
//
// 不做的事:
//   - 通知点击不做事 (guest 内 ~/Downloads 路径 host 无法跳转)
//   - 不打 badge (HVM 是 accessory app, badge 没载体)
//   - 不放声音 (粘贴是低优先级 informational, sound=nil)

import Foundation
@preconcurrency import UserNotifications
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "PasteNotifier")

@MainActor
enum HostFilePasteNotifier {

    /// 弹 "已粘贴 N 个文件到 <VM>" 原生通知. 失败 silently log + 不弹.
    static func notifySuccess(displayName: String, count: Int) {
        let body = "\(count) 个文件已传到 ~/Downloads"
        post(title: "已粘贴到 \(displayName)", body: body)
    }

    /// 弹失败 / 部分跳过的通知. ErrorDialog 在主窗口里, VM 全屏 / detached 时会被盖住,
    /// 系统通知则浮在所有窗口之上, 用户至少能看到摘要. 详情仍走 ErrorDialog 留底.
    static func notifyFailure(displayName: String, body: String) {
        post(title: "粘贴到 \(displayName) 失败", body: body)
    }

    /// 通用 info 通知 (中性 title, 非 success / failure). 给 "装 helper 中" 等任务进度反馈.
    static func notifyInfo(displayName: String, title: String, body: String) {
        post(title: "\(title) — \(displayName)", body: body)
    }

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        // 首次会弹授权; 用户拒绝后 add 仍调用但系统不显示, 不抛错.
        // requestAuthorization 是 async, 简化用 completion 闭包链式提交.
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                log.warning("UNUserNotificationCenter authorization 失败: \(error.localizedDescription, privacy: .public)")
                return
            }
            if !granted {
                log.info("UNUserNotificationCenter 未授权; 通知不显示 (用户可在系统设置开)")
                return
            }
            center.add(req) { addErr in
                if let addErr {
                    log.warning("UNUserNotificationCenter add 失败: \(addErr.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
