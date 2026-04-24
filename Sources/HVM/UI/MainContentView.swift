// MainContentView.swift
// 主窗口内容根. 左 Sidebar + 右 DetailPanel + 叠加 ErrorDialog + CreateVMDialog

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
            HStack(spacing: 0) {
                SidebarView(model: model, errors: errors)
                    .frame(width: 240)
                    .background(Color(white: 0.06))
                Divider().background(Color(white: 0.18))
                DetailPanel(model: model, errors: errors)
                    .frame(maxWidth: .infinity)
            }

            // 创建向导 (叠加, 跟 ErrorDialog 一样顺序)
            if model.showCreateWizard {
                CreateVMDialog(model: model, errors: errors)
                    .transition(.opacity)
            }

            // 错误弹窗叠最顶
            ErrorDialogOverlay(presenter: errors)
        }
        .preferredColorScheme(.dark)
        .background(Color(white: 0.04))
        .onAppear {
            model.refreshList()
        }
    }
}
