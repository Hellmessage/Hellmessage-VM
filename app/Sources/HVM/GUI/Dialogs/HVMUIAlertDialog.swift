// HVMUIAlertDialog.swift — 新 GUI 信息/警告/错误/成功提示 dialog (PR-D3)
//
// 用法:
//
//   1. 直接构造 + present (高级用法, 业务侧自管 handle):
//      dialog.present { handle in
//          HVMUI.AlertDialog(
//              level: .error,
//              title: "启动失败",
//              message: "无法连接到 vmnet daemon.",
//              hint: "检查 socket_vmnet 是否安装",
//              probeID: "dialog.error.startVM",
//              onClose: { handle.close() }
//          )
//      }
//
//   2. async API (推荐, 业务侧最常用; await 用户关闭):
//      await dialog.alert(
//          level: .error,
//          title: "启动失败",
//          message: "无法连接到 vmnet daemon.",
//          hint: "检查 socket_vmnet 是否安装",
//          probeID: "dialog.error.startVM"
//      )
//      print("alert closed, continue 后续流程")
//
// AlertLevel:
//   .info     — 蓝色 info.circle.fill, 普通信息
//   .warn     — 黄色 exclamationmark.triangle.fill, 警告
//   .error    — 红色 xmark.circle.fill, 错误
//   .success  — 绿色 checkmark.circle.fill, 成功
//
// 视觉 (跟 SimpleDialogCard / Section.elevated 同体系):
//   - bg: bgOverlay + borderEmphasis (Linear 风深色卡片)
//   - 圆角 xl, layered shadow (主层 + 近层) 强调"飘起"
//   - icon: xl (24pt), 顶部左侧, level 主色
//   - title: lg semibold, icon 右
//   - X close: 右上角 ghost icon button
//   - message: base regular textSecondary, 主体
//   - hint: xs textTertiary, 可选, message 下方
//   - footer: 单 "确定" 主按钮右侧
//
// Probe id:
//   - 业务侧传 probeID (例 "dialog.error.startVM"); AlertDialog 内派生:
//     <probeID>.confirm — 主按钮
//     <probeID>.close   — X 关闭按钮
//   - 业务侧不需要自己传子按钮 probeID

#if NEW_GUI

import SwiftUI

extension HVMUI {

enum AlertLevel {
    case info, warn, error, success

    var icon: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    fileprivate var iconColor: HVMUI.Icon.IconColor {
        switch self {
        case .info:    return .info
        case .warn:    return .warn
        case .error:   return .error
        case .success: return .success
        }
    }
}

struct AlertDialog: View {
    private let level: AlertLevel
    private let title: String
    private let message: String
    private let hint: String?
    private let confirmLabel: String
    private let probeID: String
    private let onClose: @MainActor @Sendable () -> Void

    init(level: AlertLevel,
         title: String,
         message: String,
         hint: String? = nil,
         confirmLabel: String = "确定",
         probeID: String,
         onClose: @escaping @MainActor @Sendable () -> Void) {
        self.level = level
        self.title = title
        self.message = message
        self.hint = hint
        self.confirmLabel = confirmLabel
        self.probeID = probeID
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            headerRow

            // message + hint
            VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
                Text(message)
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint {
                    Text(hint)
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // footer 主按钮右侧
            HStack {
                Spacer()
                HVMUI.Button(confirmLabel, variant: .primary,
                             probeID: "\(probeID).confirm") {
                    onClose()
                }
            }
            .padding(.top, HVMTheme.space.xs)
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 420)
        .background(cardBackground)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: HVMTheme.space.md) {
            HVMUI.Icon(level.icon, size: .xl, color: level.iconColor)

            Text(title)
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // icon 是 xl (24pt) 加 medium weight 高出 lg font 一档,
                // title 顶部对齐 icon 时视觉差不齐, 微调 4pt 让 title 视觉居中
                .padding(.top, HVMTheme.space.xs)

            HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                         probeID: "\(probeID).close") {
                onClose()
            }
        }
    }

    /// 卡片背景: bgOverlay fill + borderEmphasis stroke + layered shadow.
    /// 跟 SimpleDialogCard / Section.elevated 同套, 保持 dialog 体系视觉统一.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
            .fill(HVMTheme.color.bgOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                    .stroke(HVMTheme.color.borderEmphasis,
                            lineWidth: HVMTheme.border.hairline)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
            .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
    }
}

}  // extension HVMUI 结束

// MARK: - DialogPresenter async API

extension HVMUI.DialogPresenter {
    /// 便利 async API — 弹 alert dialog + await 用户关闭. 业务侧首选.
    ///
    /// 实现细节: present 一个 AlertDialog 进 dialog 栈, 用 CheckedContinuation
    /// 把 closure 转 async. 用户点"确定" / X / Esc 任一种关闭路径都 resume,
    /// 业务侧 await 后才继续执行.
    ///
    /// **不会被 task cancel** — alert 是同步用户响应, 没有取消语义. 业务侧
    /// 想取消应该用 .confirm (D4) 给用户选 "取消".
    func alert(level: HVMUI.AlertLevel,
               title: String,
               message: String,
               hint: String? = nil,
               confirmLabel: String = "确定",
               probeID: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // onDismiss 路径: present 的 onDismiss 在 dialog 关闭后 (任何路径:
            // X / 主按钮 handle.close() / Esc / dismissAll) 触发一次, cont.resume
            // 在那执行, 防止 Esc 关 dialog 时业务 await 永远卡住.
            present(
                { handle in
                    HVMUI.AlertDialog(
                        level: level,
                        title: title,
                        message: message,
                        hint: hint,
                        confirmLabel: confirmLabel,
                        probeID: probeID,
                        onClose: { handle.close() }
                    )
                },
                onDismiss: {
                    cont.resume()
                }
            )
        }
    }
}

#endif
