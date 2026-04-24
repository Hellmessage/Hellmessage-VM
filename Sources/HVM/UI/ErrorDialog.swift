// ErrorDialog.swift
// 统一错误弹窗, 严格按 docs/GUI.md "弹窗约束":
//   - 只能通过右上角 X 按钮关闭
//   - 禁止点击遮罩层关闭 (allowsHitTesting(false))
//   - 禁止 Esc 关闭 (不绑 Esc)
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
        if code.hasPrefix("bundle.") { return "bundle error" }
        if code.hasPrefix("storage.") { return "storage error" }
        if code.hasPrefix("backend.") { return "vm error" }
        if code.hasPrefix("install.") { return "install error" }
        if code.hasPrefix("net.") { return "network error" }
        if code.hasPrefix("ipc.") { return "ipc error" }
        if code.hasPrefix("config.") { return "config error" }
        return "error"
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
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // 顶栏
                    HStack(spacing: HVMSpace.md) {
                        Text("●")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.statusError)
                        Text(model.title.uppercased())
                            .font(HVMFont.label)
                            .tracking(1.6)
                            .foregroundStyle(HVMColor.textPrimary)
                        Spacer()
                        Button { presenter.dismissCurrent() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("关闭 (Cmd+W)")
                        .keyboardShortcut("w", modifiers: [.command])
                    }
                    .padding(.horizontal, HVMSpace.lg)
                    .padding(.vertical, HVMSpace.md)

                    Divider().background(HVMColor.border)

                    VStack(alignment: .leading, spacing: HVMSpace.md) {
                        Text(model.message)
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let d = model.details, !d.isEmpty {
                            DisclosureGroup(isExpanded: $detailsExpanded) {
                                ScrollView {
                                    Text(d)
                                        .font(HVMFont.small)
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
                                Text("details")
                                    .font(HVMFont.small)
                                    .foregroundStyle(HVMColor.textTertiary)
                            }
                        }

                        if let hint = model.hint {
                            HStack(alignment: .top, spacing: HVMSpace.sm) {
                                Text("→")
                                    .foregroundStyle(HVMColor.accent)
                                    .font(HVMFont.body)
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

                        HStack {
                            Spacer()
                            Button("DISMISS") { presenter.dismissCurrent() }
                                .buttonStyle(PrimaryButtonStyle())
                                .keyboardShortcut(.return, modifiers: [])
                        }
                    }
                    .padding(HVMSpace.lg)
                }
                .frame(width: 480)
                .background(HVMColor.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous)
                        .stroke(HVMColor.borderStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 10)
            }
            .transition(.opacity)
        }
    }
}
