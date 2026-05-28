// HVMUIConfirmDialog.swift — 新 GUI 二选一确认 dialog (PR-D4)
//
// 用法:
//
//   1. 直接构造 + present (高级用法):
//      dialog.present { handle in
//          HVMUI.ConfirmDialog(
//              title: "删除 VM?",
//              message: "VM 'ubuntu-24' 的所有数据将被删除. 不可恢复.",
//              confirmLabel: "删除",
//              destructive: true,
//              probeID: "dialog.deleteVM",
//              onResult: { result in
//                  handle.close()
//                  if result == .confirmed { deleteVM() }
//              }
//          )
//      }
//
//   2. async API (推荐):
//      let result = await dialog.confirm(
//          title: "删除 VM?",
//          message: "VM 'ubuntu-24' 的所有数据将被删除. 不可恢复.",
//          confirmLabel: "删除",
//          destructive: true,
//          probeID: "dialog.deleteVM"
//      )
//      if result == .confirmed { deleteVM() }
//
// 关闭路径 → 结果映射:
//   - 主按钮 ("删除" / "确定") → .confirmed
//   - 副按钮 ("取消") → .cancelled
//   - X 关闭 → .cancelled
//   - Esc → .cancelled
//   - presenter.dismissAll() → .cancelled
//
// destructive=true 时主按钮用 .destructive variant (红边红字),
// 业务场景: 删除 / 重置 / 加密 reset / 清除数据 等不可逆操作.
//
// 视觉: 跟 AlertDialog 同体系 (bgOverlay + borderEmphasis + 双层 shadow),
// 但不带 level icon (Linear / macOS confirm 一般不带 icon, 文案表达足够).
//
// Probe id 派生:
//   <probeID>.confirm — 主按钮
//   <probeID>.cancel  — 副按钮
//   <probeID>.close   — X 关闭

#if NEW_GUI

import SwiftUI

extension HVMUI {

enum ConfirmResult: Sendable {
    case confirmed
    case cancelled
}

struct ConfirmDialog: View {
    private let title: String
    private let message: String
    private let confirmLabel: String
    private let cancelLabel: String
    private let destructive: Bool
    private let probeID: String
    private let onResult: @MainActor @Sendable (ConfirmResult) -> Void

    init(title: String,
         message: String,
         confirmLabel: String = "确定",
         cancelLabel: String = "取消",
         destructive: Bool = false,
         probeID: String,
         onResult: @escaping @MainActor @Sendable (ConfirmResult) -> Void) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.destructive = destructive
        self.probeID = probeID
        self.onResult = onResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            headerRow

            Text(message)
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HVMTheme.space.sm) {
                Spacer()
                HVMUI.Button(cancelLabel, variant: .secondary,
                             probeID: "\(probeID).cancel") {
                    onResult(.cancelled)
                }
                HVMUI.Button(confirmLabel,
                             variant: destructive ? .destructive : .primary,
                             probeID: "\(probeID).confirm") {
                    onResult(.confirmed)
                }
            }
            .padding(.top, HVMTheme.space.xs)
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 420)
        .background(cardBackground)
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                         probeID: "\(probeID).close") {
                onResult(.cancelled)
            }
        }
    }

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

/// Resume 协调器 — 让 onResult (业务点取消 / 主按钮) 和 onDismiss (Esc / X /
/// dismissAll) 最终只 resume continuation 一次. 防 await 卡住, 防双重 resume.
@MainActor
private final class ResumeCoordinator {
    private var resumed = false
    private let cont: CheckedContinuation<HVMUI.ConfirmResult, Never>

    init(cont: CheckedContinuation<HVMUI.ConfirmResult, Never>) {
        self.cont = cont
    }

    func resumeIfNeeded(_ result: HVMUI.ConfirmResult) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: result)
    }
}

extension HVMUI.DialogPresenter {
    /// 便利 async API — 弹 confirm dialog + await 用户响应. 业务侧首选.
    ///
    /// 关闭路径 → 返回值:
    ///   - 主按钮 → .confirmed
    ///   - 取消 / X / Esc / dismissAll → .cancelled
    ///
    /// destructive=true 时主按钮 .destructive variant (红边红字),
    /// 业务场景: 删除 / 重置 / 不可逆操作.
    func confirm(title: String,
                 message: String,
                 confirmLabel: String = "确定",
                 cancelLabel: String = "取消",
                 destructive: Bool = false,
                 probeID: String) async -> HVMUI.ConfirmResult {
        await withCheckedContinuation { cont in
            let coordinator = ResumeCoordinator(cont: cont)
            present(
                { handle in
                    HVMUI.ConfirmDialog(
                        title: title,
                        message: message,
                        confirmLabel: confirmLabel,
                        cancelLabel: cancelLabel,
                        destructive: destructive,
                        probeID: probeID,
                        onResult: { result in
                            coordinator.resumeIfNeeded(result)
                            handle.close()
                        }
                    )
                },
                onDismiss: {
                    // Esc / dismissAll 直接关 dialog 没经过 onResult,
                    // onDismiss 兜底 resume .cancelled. resumeIfNeeded 保证
                    // 即使 onResult 已 resume 也不重复.
                    coordinator.resumeIfNeeded(.cancelled)
                }
            )
        }
    }
}

#endif
