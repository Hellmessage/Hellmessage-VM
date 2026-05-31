// HVMUIAlertDialog.swift — 新 GUI 信息/警告/错误/成功提示 dialog.
//
// 4 level (info/warn/error/success), 各带 level icon + 主色. 视觉跟 Section.elevated 同体系.
// 业务侧首选 async API: await dialog.alert(level:title:message:hint:probeID:), await 用户关闭.
//
// Probe id 派生: <probeID>.confirm (主按钮) / <probeID>.close (X). 业务侧只传 base probeID.


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
                // 微调 4pt 让 title 跟 xl icon 视觉居中
                .padding(.top, HVMTheme.space.xs)

            HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                         probeID: "\(probeID).close") {
                onClose()
            }
        }
    }

    /// 卡片背景: bgOverlay fill + borderEmphasis stroke + layered shadow (dialog 体系统一).
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
    /// 便利 async API — present AlertDialog + await 用户关闭 (确定 / X / Esc 任一路径都 resume).
    /// 无取消语义 (想取消用 .confirm).
    func alert(level: HVMUI.AlertLevel,
               title: String,
               message: String,
               hint: String? = nil,
               confirmLabel: String = "确定",
               probeID: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // onDismiss 在任何关闭路径 (X / 主按钮 / Esc / dismissAll) 触发一次, 防 await 卡住.
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

