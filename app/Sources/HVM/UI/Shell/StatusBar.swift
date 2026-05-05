// StatusBar.swift
// 全宽底部状态栏. 左侧统计 (n VMs · n running); 右侧版本.

import SwiftUI
import HVMCore

struct HVMStatusBar: View {
    @Bindable var model: AppModel

    /// 全局日志开关本地镜像. UserDefaults 是源, init 时读, 切换时写回 UserDefaults +
    /// 通知 LogSink. SwiftUI 用 @State 自己维护 + 渲染响应.
    @State private var loggingEnabled: Bool = LoggingPreferences.readEnabledFromDefaults()

    private var stats: (total: Int, running: Int) {
        var r = 0
        for item in model.list where item.runState == "running" {
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
                Text("Virtual Machines")
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

            // 日志开关: 关闭后 LogSink 不再写 ~/Library/Application Support/HVM/logs/<date>.log.
            // 跨进程 (CLI / VMHost) 通过 UserDefaults 共享, 下次启动也保留. 子进程自家 stderr
            // (qemu-stderr.log / swtpm.log 等) 不受影响 — 那是 Process stderr 重定向, 跟主进程
            // os.Logger 通路独立.
            Button(action: { toggleLogging() }) {
                HStack(spacing: 4) {
                    Image(systemName: loggingEnabled ? "doc.text" : "doc.text.fill.viewfinder")
                        .font(HVMFont.small)
                        .foregroundStyle(loggingEnabled ? HVMColor.accent : HVMColor.textTertiary)
                    Text(loggingEnabled ? "日志: 开" : "日志: 关")
                        .font(HVMFont.small)
                        .foregroundStyle(loggingEnabled ? HVMColor.textSecondary : HVMColor.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.plain)
            .help(loggingEnabled
                  ? "全局日志开 — 点击关闭后 HVM 主进程不再落 .log"
                  : "全局日志关 — 点击开启 (子进程 stderr / guest serial 不受本开关影响)")
            .hvmProbe(id: "statusbar.button.toggleLogging",
                       label: loggingEnabled ? "Logging On" : "Logging Off",
                       action: .button { toggleLogging() })

            Text(HVMVersion.displayString)
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
        .padding(.horizontal, HVMSpace.lg)
        .frame(height: HVMBar.statusBarHeight)
        .background(HVMColor.bgSidebar)
    }

    private func toggleLogging() {
        let newValue = !loggingEnabled
        loggingEnabled = newValue
        LoggingPreferences.setEnabled(newValue)
    }
}
