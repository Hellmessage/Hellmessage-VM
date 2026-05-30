// HVMUIWizardDialog.swift — 新 GUI 多步骤向导 dialog (PR-D6)
//
// 用法:
//
//   1. 简单 3 步向导 (例 创建 VM):
//      let result = await dialog.wizard(
//          title: "创建 VM",
//          steps: [
//              .init(title: "选 OS") { WizardChooseOSView() },
//              .init(title: "配置") { WizardConfigView() },
//              .init(title: "确认") { WizardReviewView() }
//          ],
//          probeID: "dialog.createVM"
//      )
//      if result == .completed { actuallyCreateVM() }
//
//   2. 每步用 inline closure 写小内容 (showcase 风格):
//      let result = await dialog.wizard(
//          title: "演示",
//          steps: [
//              .init(title: "第一步") { Text("hello") },
//              .init(title: "第二步") { Text("world") }
//          ],
//          probeID: "dialog.demo"
//      )
//
// 关闭路径 → 结果映射:
//   - 完成按钮 (最后一步) → .completed
//   - 取消 / X / Esc / dismissAll → .cancelled
//
// 状态机:
//   - currentIndex (0..<steps.count)
//   - 第一步: 隐藏「上一步」, 显示「下一步」
//   - 中间步: 显示「上一步」+「下一步」
//   - 最后一步: 显示「上一步」+「完成」(替换「下一步」)
//
// 步骤指示器 (顶部水平):
//   - 已完成步骤: accentMuted 填充 + checkmark + 主文字色, **可点回退**
//   - 当前步骤:   accent 填充 + 数字 + 主文字色 (highlight)
//   - 未到步骤:   bgRaised 填充 + 数字 + tertiary 文字色, **不可点**
//   - 步骤之间用细线分隔 (borderDefault)
//
// 业务侧状态管理:
//   - WizardStep.content 是 @ViewBuilder closure, 每步是独立 View
//   - 每步内部用自家 @State / @StateObject / @EnvironmentObject 持状态
//   - 跨步骤共享数据走 @EnvironmentObject (ObservableObject) 注入到 wizard,
//     或业务侧用 class-based model 捕获在 closure 内
//
// Probe id 派生:
//   <probeID>.cancel    — 左下「取消」按钮
//   <probeID>.prev      — 「上一步」(只在 idx > 0 显示)
//   <probeID>.next      — 「下一步」(只在非最后一步显示)
//   <probeID>.complete  — 「完成」(只在最后一步显示)
//   <probeID>.close     — 右上 X
//   <probeID>.step.<i>  — 步骤指示器第 i 个 chip (只在已完成步骤可点)


import SwiftUI

extension HVMUI {

/// 单步配置 — title + content closure. content 是独立 View, 每步内部
/// 自家持状态 (跨步骤共享走 @EnvironmentObject).
struct WizardStep {
    let title: String
    let content: () -> AnyView

    init<Content: View>(title: String,
                        @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = { AnyView(content()) }
    }
}

/// 提交结果 — async API 返回
enum WizardResult: Sendable {
    case completed
    case cancelled
}

struct WizardDialog: View {
    private let title: String
    private let steps: [WizardStep]
    private let probeID: String
    private let onResult: @MainActor @Sendable (WizardResult) -> Void

    @State private var currentIndex: Int = 0

    init(title: String,
         steps: [WizardStep],
         probeID: String,
         onResult: @escaping @MainActor @Sendable (WizardResult) -> Void) {
        precondition(!steps.isEmpty, "WizardDialog 至少要 1 步")
        self.title = title
        self.steps = steps
        self.probeID = probeID
        self.onResult = onResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
            headerRow

            stepIndicator

            HVMUI.Divider()

            // 当前步骤内容. 用 .id(currentIndex) 强制 SwiftUI 在切步时 rebuild,
            // 让每步 @State 干净 — 业务侧需要跨步骤持久化的数据走外部 model.
            steps[currentIndex].content()
                .id(currentIndex)
                .frame(minHeight: 120, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)

            footerRow
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 540)
        .background(cardBackground)
        .animation(HVMTheme.motion.easeOut, value: currentIndex)
    }

    // MARK: - Header

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

    // MARK: - Step indicator (顶部水平)

    private var stepIndicator: some View {
        HStack(spacing: HVMTheme.space.sm) {
            ForEach(steps.indices, id: \.self) { idx in
                stepChip(idx: idx)
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(idx < currentIndex
                              ? HVMTheme.color.accentMuted
                              : HVMTheme.color.borderDefault)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func stepChip(idx: Int) -> some View {
        let isCurrent = idx == currentIndex
        let isPast    = idx < currentIndex
        let canTap    = isPast  // 仅已完成步骤可点回退

        let chip = HStack(spacing: HVMTheme.space.xs) {
            ZStack {
                Circle()
                    .fill(circleFill(isCurrent: isCurrent, isPast: isPast))
                    .frame(width: 22, height: 22)
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HVMTheme.color.accent)
                } else {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCurrent
                                         ? HVMTheme.color.textOnAccent
                                         : HVMTheme.color.textTertiary)
                }
            }
            Text(steps[idx].title)
                .font(HVMTheme.font.sm)
                .foregroundStyle((isCurrent || isPast)
                                 ? HVMTheme.color.textPrimary
                                 : HVMTheme.color.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())

        if canTap {
            chip
                .onTapGesture {
                    currentIndex = idx
                }
                .hvmProbe(
                    id: "\(probeID).step.\(idx)",
                    label: steps[idx].title,
                    action: .button { @MainActor in
                        currentIndex = idx
                    }
                )
        } else {
            chip
        }
    }

    private func circleFill(isCurrent: Bool, isPast: Bool) -> Color {
        if isCurrent { return HVMTheme.color.accent }
        if isPast    { return HVMTheme.color.accentMuted }
        return HVMTheme.color.bgRaised
    }

    // MARK: - Footer (cancel / prev / next|complete)

    private var footerRow: some View {
        HStack(spacing: HVMTheme.space.sm) {
            HVMUI.Button("取消", variant: .ghost,
                         probeID: "\(probeID).cancel") {
                onResult(.cancelled)
            }

            Spacer()

            if currentIndex > 0 {
                HVMUI.Button("上一步", variant: .secondary,
                             probeID: "\(probeID).prev") {
                    currentIndex -= 1
                }
            }

            if currentIndex < steps.count - 1 {
                HVMUI.Button("下一步", variant: .primary,
                             probeID: "\(probeID).next") {
                    currentIndex += 1
                }
            } else {
                HVMUI.Button("完成", variant: .primary,
                             probeID: "\(probeID).complete") {
                    onResult(.completed)
                }
            }
        }
        .padding(.top, HVMTheme.space.xs)
    }

    // MARK: - Card chrome

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

/// Resume 协调器 — onResult (完成 / 取消按钮) 与 onDismiss (Esc / X / dismissAll)
/// 最终只 resume continuation 一次. 跟 Confirm / Input 同套思路, 单独泛型避免
/// 跨 dialog 文件实例化复杂度.
@MainActor
private final class WizardResumeCoordinator {
    private var resumed = false
    private let cont: CheckedContinuation<HVMUI.WizardResult, Never>

    init(cont: CheckedContinuation<HVMUI.WizardResult, Never>) {
        self.cont = cont
    }

    func resumeIfNeeded(_ result: HVMUI.WizardResult) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: result)
    }
}

extension HVMUI.DialogPresenter {
    /// 便利 async API — 弹 wizard dialog + await 用户完成或取消.
    ///
    /// 关闭路径 → 返回值:
    ///   - 「完成」(最后一步主按钮) → .completed
    ///   - 取消 / X / Esc / dismissAll → .cancelled
    ///
    /// 业务侧跨步骤共享数据走 @EnvironmentObject (ObservableObject) 注入
    /// 到外层, 或在 step.content closure 内捕获 class-based model.
    func wizard(title: String,
                steps: [HVMUI.WizardStep],
                probeID: String) async -> HVMUI.WizardResult {
        await withCheckedContinuation { cont in
            let coordinator = WizardResumeCoordinator(cont: cont)
            present(
                { handle in
                    HVMUI.WizardDialog(
                        title: title,
                        steps: steps,
                        probeID: probeID,
                        onResult: { result in
                            coordinator.resumeIfNeeded(result)
                            handle.close()
                        }
                    )
                },
                onDismiss: {
                    // Esc / dismissAll 直接关 dialog 没经过 onResult,
                    // onDismiss 兜底 resume .cancelled.
                    coordinator.resumeIfNeeded(.cancelled)
                }
            )
        }
    }
}

