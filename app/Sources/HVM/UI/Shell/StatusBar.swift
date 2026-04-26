// StatusBar.swift
// 全宽底部状态栏. 左侧统计 (n VMs · n running); 右侧版本.

import SwiftUI
import HVMCore

struct HVMStatusBar: View {
    @Bindable var model: AppModel

    private var stats: (total: Int, running: Int) {
        var r = 0
        for item in model.list where model.sessions[item.id] != nil || item.runState == "running" {
            r += 1
        }
        return (model.list.count, r)
    }

    var body: some View {
        let s = stats
        HStack(spacing: HVMSpace.md) {
            HStack(spacing: 6) {
                Text("\(s.total)")
                    .font(HVMFont.small.weight(.semibold))
                    .foregroundStyle(HVMColor.textPrimary)
                    .monospacedDigit()
                Text(s.total == 1 ? "VM" : "VMs")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
            }
            if s.running > 0 {
                Text("·")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(HVMColor.statusRunning)
                        .frame(width: 6, height: 6)
                    Text("\(s.running) running")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textSecondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Text(HVMVersion.displayString)
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(.horizontal, HVMSpace.lg)
        .frame(height: HVMBar.statusBarHeight)
        .background(HVMColor.bgSidebar)
    }
}
