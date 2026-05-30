// MainLayoutView.swift — 新 GUI 主界面骨架 (业务页 #1, M3).
//
// 两栏: toolbar / [sidebar 240 | detail] / statusbar. 自绘固定宽 sidebar (Linear 风,
// 不用 NavigationSplitView 免系统 vibrancy). 持 NewGUIStore 经 .environment 下传;
// .onAppear 启 1Hz 轮询. store.lastError 经 .onChange 冒泡成 dialog.alert (M6).


import SwiftUI
import HVMControl

struct MainLayoutView: View {
    @State private var store = NewGUIStore()
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    private static let sidebarWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NewGUISidebarView()
                    .frame(width: Self.sidebarWidth)
                vline
                DetailOverviewView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            hairline
            statusBar
        }
        .frame(minWidth: 1080, idealWidth: 1080, minHeight: 720, idealHeight: 720)
        .background(HVMTheme.color.bgBase)
        .environment(store)
        .onAppear { store.startPolling() }
        .onDisappear { store.stopPolling() }
        .onChange(of: store.lastError) { _, newValue in
            guard let err = newValue else { return }
            Task { @MainActor in
                await dialog.alert(
                    level: .error,
                    title: err.title,
                    message: err.message,
                    hint: err.hint,
                    probeID: "main.alert.error"
                )
                store.lastError = nil
            }
        }
    }

    // MARK: - 装饰

    private var hairline: some View {
        Rectangle()
            .fill(HVMTheme.color.borderDefault)
            .frame(height: 1)
    }

    private var vline: some View {
        Rectangle()
            .fill(HVMTheme.color.borderDefault)
            .frame(width: 1)
    }

    private var statusBar: some View {
        HStack(spacing: HVMTheme.space.sm) {
            Text("\(store.vms.count) 台 VM")
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
            Text("·")
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
            let runningCount = store.vms.filter { $0.runState == .running }.count
            Text("\(runningCount) 运行中")
                .font(HVMTheme.font.xs)
                .foregroundStyle(runningCount > 0
                                 ? HVMTheme.color.success
                                 : HVMTheme.color.textTertiary)
            Spacer()
            // 刷新作为状态栏工具图标 (列表 1Hz 自动刷新, 此为手动兜底)
            HVMUI.Button(icon: "arrow.clockwise", variant: .ghost, size: .sm,
                         probeID: "statusbar.button.refresh") {
                store.refresh()
            }
        }
        .padding(.horizontal, HVMTheme.space.md)
        .frame(height: 28)
        .background(HVMTheme.color.bgRaised)
    }
}

