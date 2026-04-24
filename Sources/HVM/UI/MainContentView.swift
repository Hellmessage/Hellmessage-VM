// MainContentView.swift
// 主窗口布局: 顶 toolbar + 中 HStack (sidebar | detail) + 底 status bar
// 顶/底全宽跨左右栏, 强制两栏 top/bottom baseline 对齐

import SwiftUI
import HVMCore

public struct MainContentView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    public init(model: AppModel, errors: ErrorPresenter) {
        self._model = Bindable(model)
        self._errors = Bindable(errors)
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HVMToolbar(model: model, errors: errors)
                HStack(spacing: 0) {
                    SidebarView(model: model, errors: errors)
                        .frame(width: 240)
                    Rectangle()
                        .fill(HVMColor.border)
                        .frame(width: 1)
                    DetailPanel(model: model, errors: errors)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HVMStatusBar(model: model)
            }

            if model.showCreateWizard {
                CreateVMDialog(model: model, errors: errors)
                    .transition(.opacity)
            }

            ErrorDialogOverlay(presenter: errors)
        }
        .preferredColorScheme(.dark)
        .background(HVMColor.bgBase)
        .onAppear { model.refreshList() }
    }
}
