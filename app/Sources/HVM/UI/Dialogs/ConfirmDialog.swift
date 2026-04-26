// ConfirmDialog.swift
// 通用确认弹窗 (双按钮: 取消 / 确认), 视觉跟 ErrorDialog 一致.
//
// 严格按 docs/GUI.md 弹窗约束:
//   - 只能通过右上角 X 按钮关闭 (= 取消)
//   - 禁止点击遮罩层关闭 (allowsHitTesting(false))
//   - 禁止 Esc 关闭
//   - 禁止 NSAlert / .alert()
//
// 跟 ErrorPresenter 区别: 一次只允许一个 confirm pending (不排队), 因为 confirm 通常带回调
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
    /// 用户选择回调. Bool: true = 确认, false = 取消/X.
    /// closure 用 nonObservable storage 避免 SwiftUI 把它当观察对象
    @ObservationIgnored
    private var resolver: ((Bool) -> Void)? = nil

    public init() {}

    /// 弹出 confirm. action 在用户做出选择后调用一次, 之后清空.
    /// 如果已有 pending confirm, 会被 cancel(false) 后立刻覆盖.
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
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // 顶栏
                    HStack(spacing: HVMSpace.md) {
                        Text("●")
                            .font(HVMFont.caption)
                            .foregroundStyle(model.destructive
                                              ? HVMColor.danger
                                              : HVMColor.accent)
                        Text(model.title.uppercased())
                            .font(HVMFont.label)
                            .tracking(1.6)
                            .foregroundStyle(HVMColor.textPrimary)
                        Spacer()
                        Button { presenter.resolve(false) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("关闭 (Cmd+W) — 等同取消")
                        .keyboardShortcut("w", modifiers: [.command])
                    }
                    .padding(.horizontal, HVMSpace.lg)
                    .padding(.vertical, HVMSpace.md)

                    Divider().background(HVMColor.border)

                    VStack(alignment: .leading, spacing: HVMSpace.lg) {
                        Text(model.message)
                            .font(HVMFont.body)
                            .foregroundStyle(HVMColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: HVMSpace.md) {
                            Spacer()
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
                    .padding(HVMSpace.lg)
                }
                .frame(width: 420)
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
