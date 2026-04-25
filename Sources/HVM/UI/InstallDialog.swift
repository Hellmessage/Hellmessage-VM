// InstallDialog.swift
// macOS guest 装机进度模态. AppModel.installState 非 nil 时由 DialogOverlay 显示.
//
// 不提供 Cancel: VZMacOSInstaller 没有可靠取消语义, 中断会留下半成品 auxiliary
// (hardware-model 已绑定, 重装也只能删整个 bundle). 装机过程一般 10-30 分钟,
// 用户必须等. 失败走 errors.present 标准错误弹窗.

import SwiftUI

struct InstallDialog: View {
    let state: AppModel.InstallProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Divider().background(HVMColor.border)
                body_
            }
            .frame(width: 480)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg))
            .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
        }
    }

    private var header: some View {
        HStack(spacing: HVMSpace.md) {
            Text("Installing macOS")
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
            Spacer()
            // 故意不放 X 关闭: 装机不能被打断. 失败由 errors.present 接管.
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: HVMSpace.lg) {
            // VM 名 + 阶段标签
            HStack(spacing: HVMSpace.sm) {
                Text(state.displayName)
                    .font(HVMFont.bodyBold)
                    .foregroundStyle(HVMColor.textPrimary)
                Spacer()
                Text(phaseLabel)
                    .font(HVMFont.label)
                    .tracking(1.5)
                    .foregroundStyle(HVMColor.textTertiary)
            }

            // 进度条 + 百分比 (installing 阶段才有具体数值)
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                progressBar
                Text(percentLabel)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
                    .monospacedDigit()
            }

            Text("// 装机过程不可中断, 请耐心等待. 完成后自动关闭此对话框.")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(HVMSpace.lg)
    }

    private var phaseLabel: String {
        switch state.phase {
        case .preparing:  return "PREPARING"
        case .installing: return "INSTALLING"
        case .finalizing: return "FINALIZING"
        }
    }

    private var percentLabel: String {
        switch state.phase {
        case .preparing:  return "validating ipsw + writing auxiliary…"
        case .installing: return String(format: "%.1f%%", state.fraction * 100)
        case .finalizing: return "writing config (autoInstalled=true)…"
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.bgBase)
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .fill(HVMColor.accent)
                    .frame(width: max(2, geo.size.width * fillFraction))
                    .animation(.easeOut(duration: 0.15), value: fillFraction)
            }
        }
        .frame(height: 6)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    private var fillFraction: CGFloat {
        switch state.phase {
        case .preparing:  return 0.02       // 一点点动起来
        case .installing: return CGFloat(state.fraction)
        case .finalizing: return 1.0
        }
    }
}
