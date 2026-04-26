// StatusBar.swift
// 全宽底部状态栏. 跨左右栏, 显示统计 + 版本

import SwiftUI
import HVMCore

struct HVMStatusBar: View {
    @Bindable var model: AppModel

    private var stats: (linux: Int, macOS: Int, windows: Int, running: Int) {
        var l = 0, m = 0, w = 0, r = 0
        for item in model.list {
            switch item.guestOS {
            case .linux:   l += 1
            case .macOS:   m += 1
            case .windows: w += 1
            }
            if model.sessions[item.id] != nil || item.runState == "running" {
                r += 1
            }
        }
        return (l, m, w, r)
    }

    var body: some View {
        let s = stats
        HStack(spacing: HVMSpace.lg) {
            // 左: 统计
            HStack(spacing: HVMSpace.md) {
                statItem(label: "linux", value: "\(s.linux)")
                statItem(label: "macos", value: "\(s.macOS)")
                if s.windows > 0 {
                    // windows 仅当存在时才占位 (创建向导默认不出 windows 选项)
                    statItem(label: "windows", value: "\(s.windows)")
                }
                statItem(label: "running",
                         value: "\(s.running)",
                         valueColor: s.running > 0 ? HVMColor.statusRunning : HVMColor.textSecondary)
            }

            Spacer()

            // 右: 版本
            Text(HVMVersion.displayString.lowercased())
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(.horizontal, HVMSpace.lg)
        .frame(height: HVMBar.statusBarHeight)
        .background(HVMColor.bgBase)
        .overlay(
            Rectangle()
                .fill(HVMColor.border)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    @ViewBuilder
    private func statItem(label: String, value: String,
                          valueColor: Color = HVMColor.textSecondary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Text("=")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
            Text(value)
                .font(HVMFont.small)
                .foregroundStyle(valueColor)
        }
    }
}
