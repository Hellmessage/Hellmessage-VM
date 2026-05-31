// HVMUIWizardDialog.swift — 新 GUI 多步骤向导 dialog. 顶部步骤指示器 + 上一步/下一步/完成导航.
//
// 关闭路径 → 结果: 完成按钮 → .completed; 取消 / X / Esc / dismissAll → .cancelled.
// 步骤指示器: 已完成 (checkmark, 可点回退) / 当前 (accent highlight) / 未到 (tertiary, 不可点).
// 跨步骤共享数据走 @EnvironmentObject 注入或 closure 内捕获 class-based model.
//
// 业务侧首选 async API: dialog.wizard(title:steps:probeID:).
// Probe id 派生: <probeID>.cancel / .prev / .next / .complete / .close / .step.<i> (仅已完成步可点).


import SwiftUI

extension HVMUI {

/// 单步配置 — title + content closure (独立 View, 跨步骤共享走 @EnvironmentObject).
/// canAdvance: 该步字段是否合法 — 不合法时 "下一步/完成" disable (默认恒可前进).
struct WizardStep {
    let title: String
    let content: () -> AnyView
    let canAdvance: () -> Bool

    init<Content: View>(title: String,
                        canAdvance: @escaping () -> Bool = { true },
                        @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.canAdvance = canAdvance
        self.content = { AnyView(content()) }
    }
}

/// 提交结果 — async API 返回
enum WizardResult: Sendable {
    case completed
    case cancelled
}

/// onComplete 异步收尾结果 — success → .completed; failure → 回 form 显内联 error.
enum WizardCompletion: Sendable {
    case success
    case failure(String)
}

struct WizardDialog: View {
    private let title: String
    private let steps: [WizardStep]
    private let probeID: String
    private let onResult: @MainActor @Sendable (WizardResult) -> Void
    // 可选异步收尾: "完成" 按下后切 running 态跑它. 不传 → "完成" 即 .completed (退化为原行为).
    private let onComplete: (@MainActor @Sendable () async -> WizardCompletion)?
    private let completionLabel: String

    @State private var currentIndex: Int = 0
    @State private var isRunning: Bool = false
    @State private var inlineError: String?

    init(title: String,
         steps: [WizardStep],
         probeID: String,
         completionLabel: String = "处理中…",
         onComplete: (@MainActor @Sendable () async -> WizardCompletion)? = nil,
         onResult: @escaping @MainActor @Sendable (WizardResult) -> Void) {
        precondition(!steps.isEmpty, "WizardDialog 至少要 1 步")
        self.title = title
        self.steps = steps
        self.probeID = probeID
        self.completionLabel = completionLabel
        self.onComplete = onComplete
        self.onResult = onResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.lg) {
            headerRow

            stepIndicator

            HVMUI.Divider()

            if isRunning {
                runningView
                    .frame(minHeight: 120, alignment: .center)
                    .frame(maxWidth: .infinity)
            } else {
                // .id(currentIndex) 强制切步时 rebuild, 让每步 @State 干净 (跨步持久化走外部 model)
                steps[currentIndex].content()
                    .id(currentIndex)
                    .frame(minHeight: 120, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    // content 内 Select 下拉走 .overlay 往下浮, 会盖到 footerRow 区域;
                    // VStack 里靠后的 footerRow 默认画在其上 → 按钮穿透下拉. 抬 content zIndex 压住.
                    .zIndex(1)

                if let inlineError {
                    Text(inlineError)
                        .font(HVMTheme.font.sm)
                        .foregroundStyle(HVMTheme.color.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footerRow
            }
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 540)
        .background(cardBackground)
        .animation(HVMTheme.motion.easeOut, value: currentIndex)
        .animation(HVMTheme.motion.easeOut, value: isRunning)
    }

    // MARK: - running 态 (onComplete 跑期间; 不可中断, X + 导航全隐)

    private var runningView: some View {
        HStack(spacing: HVMTheme.space.sm) {
            ProgressView().scaleEffect(0.7)
            Text(completionLabel)
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textPrimary)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // running 不可关 (X 隐藏, onComplete 事务不可中断)
            if !isRunning {
                HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                             probeID: "\(probeID).close") {
                    onResult(.cancelled)
                }
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
        let canTap    = isPast && !isRunning  // 仅已完成步骤可点回退; running 锁定

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
                             disabled: !steps[currentIndex].canAdvance(),
                             probeID: "\(probeID).next") {
                    if steps[currentIndex].canAdvance() { currentIndex += 1 }
                }
            } else {
                HVMUI.Button("完成", variant: .primary,
                             disabled: !steps[currentIndex].canAdvance(),
                             probeID: "\(probeID).complete") {
                    complete()
                }
            }
        }
        .padding(.top, HVMTheme.space.xs)
    }

    /// "完成" 处理: 无 onComplete → 直接 .completed; 有则切 running 跑它, 失败回 form 显内联 error.
    private func complete() {
        guard steps[currentIndex].canAdvance() else { return }
        guard let onComplete else {
            onResult(.completed)
            return
        }
        inlineError = nil
        isRunning = true
        Task { @MainActor in
            let result = await onComplete()
            switch result {
            case .success:
                onResult(.completed)            // 由 present 包装 resume + close
            case .failure(let msg):
                isRunning = false
                inlineError = msg               // 回 form 当前步显红字
            }
        }
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

/// Resume 协调器 — 跟 Confirm / Input 同套思路, 单独一份避免跨 dialog 文件实例化.
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
    /// 便利 async API — present wizard dialog + await 用户完成或取消.
    /// 完成 → .completed; 取消 / X / Esc / dismissAll → .cancelled.
    /// onComplete 非 nil 时: "完成" 切 running 跑它, .success 才 .completed (resume+close),
    /// .failure 回 form 显内联 error (dialog 不关, continuation 不 resume).
    func wizard(title: String,
                steps: [HVMUI.WizardStep],
                probeID: String,
                completionLabel: String = "处理中…",
                onComplete: (@MainActor @Sendable () async -> HVMUI.WizardCompletion)? = nil) async -> HVMUI.WizardResult {
        await withCheckedContinuation { cont in
            let coordinator = WizardResumeCoordinator(cont: cont)
            present(
                { handle in
                    HVMUI.WizardDialog(
                        title: title,
                        steps: steps,
                        probeID: probeID,
                        completionLabel: completionLabel,
                        onComplete: onComplete,
                        onResult: { result in
                            coordinator.resumeIfNeeded(result)
                            handle.close()
                        }
                    )
                },
                onDismiss: {
                    // Esc / dismissAll 不经过 onResult, 这里兜底 resume .cancelled
                    coordinator.resumeIfNeeded(.cancelled)
                }
            )
        }
    }
}

