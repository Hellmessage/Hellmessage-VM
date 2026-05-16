// StatusBar.swift
// 全宽底部状态栏. 左侧统计 (n VMs · n running); 右侧版本.

import SwiftUI
import HVMCore

struct HVMStatusBar: View {
    @Bindable var model: AppModel

    /// 全局日志开关本地镜像. UserDefaults 是源, init 时读, 切换时写回 UserDefaults +
    /// 通知 LogSink. SwiftUI 用 @State 自己维护 + 渲染响应.
    @State private var loggingEnabled: Bool = LoggingPreferences.readEnabledFromDefaults()
    /// 全局缩略图开关本地镜像. 同 LoggingPreferences 的模式.
    @State private var thumbnailsEnabled: Bool = ThumbnailPreferences.readEnabledFromDefaults()

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

            // vmnet daemon 快捷入口: 点击弹 popover (状态 + 安装/卸载按钮),
            // 安装时 bridged 集合自动汇总 model.list 所有 VM. 见 StatusBarVmnet.swift.
            HVMStatusBarVmnetButton(model: model)

            // 缩略图开关: 关闭后 VZ / QEMU 抓帧定时器 short-circuit, 不再写
            // bundle/meta/thumbnail.png; 状态栏 popover 显示占位图标. 已有 .png 不主动删.
            Button(action: { toggleThumbnails() }) {
                HStack(spacing: 4) {
                    Image(systemName: thumbnailsEnabled ? "photo" : "photo.badge.exclamationmark")
                        .font(HVMFont.small)
                        .foregroundStyle(thumbnailsEnabled ? HVMColor.accent : HVMColor.textTertiary)
                    Text(thumbnailsEnabled ? "缩略图: 开" : "缩略图: 关")
                        .font(HVMFont.small)
                        .foregroundStyle(thumbnailsEnabled ? HVMColor.textSecondary : HVMColor.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.plain)
            .help(thumbnailsEnabled
                  ? "缩略图开 — 运行中 VM 周期截图 (10s), 状态栏 popover 显示真实画面"
                  : "缩略图关 — 不再周期截图, popover 显示占位图标 (已有 thumbnail.png 不删)")
            .hvmProbe(id: "statusbar.button.toggleThumbnails",
                       label: thumbnailsEnabled ? "Thumbnails On" : "Thumbnails Off",
                       action: .button { toggleThumbnails() })

            // 日志开关: 关闭后 host 侧所有诊断 .log 全部不落盘 —
            //   - LogSink 顶层 ~/Library/Application Support/HVM/logs/<date>.log
            //   - per-VM 子目录 host-<date>.log / qemu-stderr.log / swtpm.log / swtpm-stderr.log
            // 跨进程 (CLI / VMHost) 通过 com.hellmessage.vm UserDefaults suite 共享, 下次启动
            // 也保留. guest 自身 serial console-*.log (在 bundle/logs/) 是 guest 的输出,
            // 不在本开关范围.
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
                  ? "全局日志开 — 点击关闭后 HVM 全部 host 侧 .log 不再落盘 (含子进程 qemu/swtpm)"
                  : "全局日志关 — 点击开启 (guest serial console-*.log 始终落 bundle, 不受本开关影响)")
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

    private func toggleThumbnails() {
        let newValue = !thumbnailsEnabled
        thumbnailsEnabled = newValue
        ThumbnailPreferences.setEnabled(newValue)
    }
}
