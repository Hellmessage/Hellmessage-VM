// ErrorDialog.swift
// 统一错误弹窗, 套 HVMModal 容器.
//   - 只能通过右上角 X 按钮关闭
//   - 禁止点击遮罩层关闭
//   - 禁止 Esc 关闭
//   - 禁止 NSAlert / SwiftUI .alert()
//   - 多错误排队顺序展示

import SwiftUI
import HVMCore

public struct ErrorDialogModel: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let details: String?
    public let hint: String?

    public static func == (lhs: ErrorDialogModel, rhs: ErrorDialogModel) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
public final class ErrorPresenter {
    public private(set) var queue: [ErrorDialogModel] = []
    public init() {}
    public var current: ErrorDialogModel? { queue.first }

    public func present(_ model: ErrorDialogModel) {
        queue.append(model)
    }

    public func present(_ error: Error) {
        let ufm: UserFacingError
        if let e = error as? HVMError {
            ufm = e.userFacing
        } else {
            ufm = UserFacingError(code: "unknown", message: "\(error)")
        }
        var details = ufm.details.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if details.isEmpty, ufm.code != "unknown" { details = "code: \(ufm.code)" }
        present(ErrorDialogModel(
            title: titleForCode(ufm.code),
            message: ufm.message,
            details: details.isEmpty ? nil : details,
            hint: ufm.hint
        ))
    }

    public func dismissCurrent() {
        if !queue.isEmpty { queue.removeFirst() }
    }

    private func titleForCode(_ code: String) -> String {
        if code.hasPrefix("bundle.")  { return "Bundle Error" }
        if code.hasPrefix("storage.") { return "Storage Error" }
        if code.hasPrefix("backend.") { return "VM Error" }
        if code.hasPrefix("install.") { return "Install Error" }
        if code.hasPrefix("net.")     { return "Network Error" }
        if code.hasPrefix("ipc.")     { return "IPC Error" }
        if code.hasPrefix("config.")  { return "Config Error" }
        return "Error"
    }
}

public struct ErrorDialogOverlay: View {
    @Bindable var presenter: ErrorPresenter
    @State private var detailsExpanded = false

    public init(presenter: ErrorPresenter) {
        self._presenter = Bindable(presenter)
    }

    public var body: some View {
        if let model = presenter.current {
            HVMModal(
                title: model.title,
                icon: .error,
                width: 480,
                closeAction: { presenter.dismissCurrent(); detailsExpanded = false }
            ) {
                VStack(alignment: .leading, spacing: HVMSpace.md) {
                    Text(model.message)
                        .font(HVMFont.body)
                        .foregroundStyle(HVMColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let d = model.details, !d.isEmpty {
                        DisclosureGroup(isExpanded: $detailsExpanded) {
                            ScrollView {
                                Text(d)
                                    .font(HVMFont.monoSmall)
                                    .foregroundStyle(HVMColor.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(HVMSpace.sm)
                            }
                            .frame(maxHeight: 140)
                            .background(
                                RoundedRectangle(cornerRadius: HVMRadius.sm)
                                    .fill(HVMColor.bgBase)
                            )
                        } label: {
                            Text("Details")
                                .font(HVMFont.small)
                                .foregroundStyle(HVMColor.textTertiary)
                        }
                    }

                    if let hint = model.hint {
                        HStack(alignment: .top, spacing: HVMSpace.sm) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(HVMColor.accent)
                                .font(HVMFont.small)
                            Text(hint)
                                .font(HVMFont.caption)
                                .foregroundStyle(HVMColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(HVMSpace.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: HVMRadius.sm)
                                .fill(HVMColor.accentMuted)
                        )
                    }
                }
            } footer: {
                HVMModalFooter {
                    Button("Dismiss") { presenter.dismissCurrent(); detailsExpanded = false }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
    }
}
