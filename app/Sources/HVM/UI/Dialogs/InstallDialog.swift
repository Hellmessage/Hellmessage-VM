// InstallDialog.swift
// macOS guest 装机进度模态. 套 HVMModal, closeAction = nil (装机不可中断).
// 失败走 errors.present 标准错误弹窗.

import SwiftUI

struct InstallDialog: View {
    let state: AppModel.InstallProgressState

    var body: some View {
        HVMModal(
            title: "Installing macOS",
            icon: .info,
            width: 480,
            closeAction: nil
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                HStack(spacing: HVMSpace.sm) {
                    Text(state.displayName)
                        .font(HVMFont.bodyBold)
                        .foregroundStyle(HVMColor.textPrimary)
                    Spacer()
                    Text(phaseLabel)
                        .font(HVMFont.label)
                        .foregroundStyle(HVMColor.textTertiary)
                }

                VStack(alignment: .leading, spacing: HVMSpace.xs) {
                    progressBar
                    Text(percentLabel)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textSecondary)
                        .monospacedDigit()
                }

                Text("装机过程不可中断, 请耐心等待. 完成后自动关闭此对话框.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phaseLabel: String {
        switch state.phase {
        case .preparing:  return "Preparing"
        case .installing: return "Installing"
        case .finalizing: return "Finalizing"
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
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.sm))
        }
        .frame(height: 6)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(HVMColor.border, lineWidth: 1)
        )
    }

    private var fillFraction: CGFloat {
        switch state.phase {
        case .preparing:  return 0.02
        case .installing: return CGFloat(state.fraction)
        case .finalizing: return 1.0
        }
    }
}
