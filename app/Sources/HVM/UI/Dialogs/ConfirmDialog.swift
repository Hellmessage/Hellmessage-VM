// ConfirmDialog.swift
// 通用确认弹窗 (双按钮: 取消 / 确认), 套 HVMModal 容器.
//
// 严格按 docs/GUI.md 弹窗约束:
//   - 只能通过右上角 X 关闭 (= 取消)
//   - 禁止点击遮罩层关闭
//   - 禁止 Esc 关闭
//   - 禁止 NSAlert / .alert()
//
// 跟 ErrorPresenter 区别: 一次只允许一个 confirm pending (不排队), 因为 confirm 通常带回调,
// 一旦回调走了再来一个 confirm 在同一时间没语义.

import SwiftUI

public struct ConfirmDialogModel: Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let cancelTitle: String
    public let destructive: Bool

    public init(title: String, message: String,
                confirmTitle: String = "确认", cancelTitle: String = "取消",
                destructive: Bool = false) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.destructive = destructive
    }
}

@MainActor
@Observable
public final class ConfirmPresenter {
    public private(set) var current: ConfirmDialogModel? = nil
    @ObservationIgnored
    private var resolver: ((Bool) -> Void)? = nil

    public init() {}

    public func present(_ model: ConfirmDialogModel, action: @escaping @MainActor (Bool) -> Void) {
        if let prev = resolver { prev(false) }
        current = model
        resolver = action
    }

    public func resolve(_ confirmed: Bool) {
        let r = resolver
        current = nil
        resolver = nil
        r?(confirmed)
    }
}

public struct ConfirmDialogOverlay: View {
    @Bindable var presenter: ConfirmPresenter

    public init(presenter: ConfirmPresenter) {
        self._presenter = Bindable(presenter)
    }

    public var body: some View {
        if let model = presenter.current {
            HVMModal(
                title: model.title,
                icon: model.destructive ? .warning : .info,
                width: 440,
                closeAction: { presenter.resolve(false) }
            ) {
                Text(model.message)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                HVMModalFooter {
                    Button(model.cancelTitle) { presenter.resolve(false) }
                        .buttonStyle(GhostButtonStyle())
                    if model.destructive {
                        Button(model.confirmTitle) { presenter.resolve(true) }
                            .buttonStyle(GhostButtonStyle(destructive: true))
                    } else {
                        Button(model.confirmTitle) { presenter.resolve(true) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
    }
}
