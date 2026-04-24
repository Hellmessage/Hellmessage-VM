// ErrorDialog.swift
// 统一错误弹窗. 严格按 docs/GUI.md "弹窗约束":
//   - 只能通过右上角 X 按钮关闭
//   - 禁止点击遮罩层关闭 (遮罩 allowsHitTesting(false))
//   - 禁止 Esc 关闭 (不绑 Esc keyboard shortcut)
//   - 禁止 NSAlert / SwiftUI .alert()
//   - 多错误排队顺序展示

import SwiftUI
import HVMCore

/// 单次错误展示数据模型
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

/// 错误呈现器. 支持排队, 同时只显示一个.
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
        if code.hasPrefix("bundle.") { return "Bundle 错误" }
        if code.hasPrefix("storage.") { return "磁盘错误" }
        if code.hasPrefix("backend.") { return "VM 运行错误" }
        if code.hasPrefix("install.") { return "安装错误" }
        if code.hasPrefix("net.") { return "网络错误" }
        if code.hasPrefix("ipc.") { return "通信错误" }
        if code.hasPrefix("config.") { return "配置错误" }
        return "错误"
    }
}

// MARK: - SwiftUI View

public struct ErrorDialogOverlay: View {
    @Bindable var presenter: ErrorPresenter

    public init(presenter: ErrorPresenter) {
        self._presenter = Bindable(presenter)
    }

    public var body: some View {
        if let model = presenter.current {
            ZStack {
                // 遮罩层 — 关键: allowsHitTesting(false) 保证点击不拦截也不关闭
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // 顶部 title bar + X 按钮
                    HStack {
                        Text(model.title)
                            .font(.headline)
                            .foregroundStyle(Color(white: 0.95))
                        Spacer()
                        Button(action: { presenter.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(white: 0.8))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("关闭 (Cmd+W)")
                        .keyboardShortcut("w", modifiers: [.command])
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().background(Color(white: 0.2))

                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.message)
                            .foregroundStyle(Color(white: 0.92))

                        if let d = model.details {
                            ScrollView {
                                Text(d)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(white: 0.75))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 140)
                            .padding(8)
                            .background(Color(white: 0.08))
                            .cornerRadius(4)
                        }

                        if let hint = model.hint {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                                Text(hint)
                                    .foregroundStyle(Color(white: 0.85))
                            }
                            .font(.system(size: 12))
                        }

                        HStack {
                            Spacer()
                            Button("好") { presenter.dismissCurrent() }
                                .keyboardShortcut(.return, modifiers: [])
                        }
                    }
                    .padding(16)
                }
                .background(Color(white: 0.08))
                .cornerRadius(10)
                .frame(width: 480)
                .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 8)
            }
            .transition(.opacity)
        }
    }
}
