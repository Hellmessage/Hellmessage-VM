// HVMUIDialogHost.swift — 新 GUI 全局浮窗容器.
//
// 根视图加 .hvmDialogHost() modifier, 内部 ZStack 渲染层在所有 ScrollView / sectionCard / VStack
// 层级之外, 浮窗脱离父级 clip / border / 渲染顺序限制. 业务侧 @EnvironmentObject dialog → present { ... }.
//
// **接入位置铁律**: .hvmDialogHost() 必须套在 NSHostingController rootView 外层 (作根 view 祖先),
// 否则根 view 评估时 environment 还没注入, fatal "No ObservableObject of type DialogPresenter found".
//
// 支持嵌套 present (栈顶接收交互); handle.close() 关栈顶, dismissAll() 关全部.
// 蒙底 bgBase 60% opacity, 不可点关 (GUI 约束: 仅 X 按钮关闭). FocusTrap (Tab 锁卡片内) + EscRouter (Esc 关栈顶).


import SwiftUI

extension HVMUI {

/// 全局浮窗管理器. 用 ObservableObject 而非 @Observable — macOS 14 上 @Observable 配
/// environment 注入 subscribe 时序不稳定, @StateObject + @EnvironmentObject 老 API 更可靠.
@MainActor
final class DialogPresenter: ObservableObject {
    /// 当前显示的 dialog 栈 (栈顶在 last). 多 dialog 嵌套时按入栈顺序渲染.
    @Published fileprivate var stack: [DialogEntry] = []

    /// nonisolated init: 让 default 实例能在 nonisolated context 初始化.
    /// mutation (present/dismiss) 仍只能在 MainActor 上.
    nonisolated init() {}

    /// 推一个浮窗到栈顶, 返回 handle. content closure 接收 DialogHandle 用于关闭自己.
    /// onDismiss: 任何关闭路径 (X / 主按钮 / Esc / dismissAll) 触发一次, async API 用它接 continuation.resume.
    @discardableResult
    func present<Content: View>(
        @ViewBuilder _ content: (DialogHandle) -> Content,
        onDismiss: (@MainActor @Sendable () -> Void)? = nil
    ) -> DialogHandle {
        let id = UUID()
        let handle = DialogHandle(id: id, presenter: self)
        let view = AnyView(content(handle))
        stack.append(DialogEntry(id: id, contentView: view, onDismiss: onDismiss))
        return handle
    }

    /// 关闭栈顶 dialog (例如 Esc 键 / X 按钮触发). 触发 onDismiss callback.
    func dismissTop() {
        guard let last = stack.popLast() else { return }
        last.onDismiss?()
    }

    /// 关闭指定 dialog (handle.close() 调用). 触发 onDismiss callback.
    func dismiss(id: UUID) {
        guard let idx = stack.firstIndex(where: { $0.id == id }) else { return }
        let entry = stack.remove(at: idx)
        entry.onDismiss?()
    }

    /// 一次性关闭所有 (例如登出 / 切 VM 等强制关闭场景). 触发所有 onDismiss.
    func dismissAll() {
        let entries = stack
        stack.removeAll()
        for entry in entries {
            entry.onDismiss?()
        }
    }

    /// 当前栈深 (业务侧判断是否有 dialog 打开)
    var isPresenting: Bool { !stack.isEmpty }
}

/// 单个 dialog 入栈项. fileprivate 让外部只能通过 present API 创建.
fileprivate struct DialogEntry: Identifiable {
    let id: UUID
    let contentView: AnyView
    /// 关闭时回调 — 不论关闭路径 (X / 主按钮 / Esc / dismissAll) 都触发.
    /// async API 用它把 CheckedContinuation.resume() 接进所有关闭路径.
    let onDismiss: (@MainActor @Sendable () -> Void)?
}

/// Dialog 操作 handle. present 返回, 业务侧用它关闭自己; weak presenter 防循环引用.
struct DialogHandle {
    let id: UUID
    weak var presenter: DialogPresenter?

    @MainActor
    func close() {
        presenter?.dismiss(id: id)
    }
}

/// 根视图 ViewModifier — 把 dialog 渲染到 root-level ZStack, 脱离父级层级.
/// FocusTrap: dialog 显示时 .disabled 背景 content, Tab 锁在 dialog 内.
/// EscRouter: dialog 渲染层 .onKeyPress(.escape) 关栈顶; 没 dialog 时透给业务 (framebuffer Esc 给 guest).
struct DialogHostModifier: ViewModifier {
    @StateObject private var presenter = DialogPresenter()
    @FocusState private var dialogFocused: Bool

    func body(content: Content) -> some View {
        ZStack {
            content
                .environmentObject(presenter)
                // FocusTrap: 背景 disabled 让 focusable views 失活, Tab 不跑出 dialog
                .disabled(presenter.isPresenting)

            // Dialog 渲染层 — 极高 zIndex, 浮在所有内容之上.
            if presenter.isPresenting {
                ZStack {
                    // 蒙底: bgBase 60% opacity, 不可点关 (CLAUDE.md GUI 约束)
                    HVMTheme.color.bgBase.opacity(0.6)
                        .ignoresSafeArea()

                    // Dialog 内容: 栈结构, 后入栈的浮在前面 (zIndex 递增)
                    ForEach(Array(presenter.stack.enumerated()), id: \.element.id) { idx, entry in
                        entry.contentView
                            .transition(.opacity.combined(
                                with: .scale(scale: 0.97, anchor: .center)
                            ))
                            .zIndex(Double(idx))
                    }
                }
                .transition(.opacity)
                // EscRouter: SwiftUI .focused + .onKeyPress 路径, dismissTop 前
                // 显式 dialogFocused = false 释放 first responder, 防 dialog
                // 消失后 first responder 卡死.
                .focusable()
                .focusEffectDisabled()
                .focused($dialogFocused)
                .onAppear { dialogFocused = true }
                .onChange(of: presenter.stack.count) { _, newCount in
                    // 嵌套 dialog 关一层后外层仍在, re-focus 让下次 Esc 仍能关
                    if newCount > 0 {
                        dialogFocused = true
                    }
                }
                .onKeyPress(.escape) {
                    if presenter.isPresenting {
                        // 关闭前显式 unfocus 释放 first responder, 防卡死
                        dialogFocused = false
                        presenter.dismissTop()
                        return .handled
                    }
                    return .ignored
                }
                // 高 zIndex 确保浮在所有业务 zIndex 之上. 不用 .greatestFiniteMagnitude
                // (SwiftUI 浮点比较跟其他高 zIndex 共存时不稳定 → dialog 消失); 999_999 够大.
                .zIndex(999_999)
            }
        }
        .animation(HVMTheme.motion.easeOut, value: presenter.stack.count)
    }
}

}  // extension HVMUI 结束

// 业务侧用 @EnvironmentObject private var dialog: HVMUI.DialogPresenter (DialogHostModifier 内 .environmentObject 注入).

extension View {
    /// 把当前 view 设为 dialog 渲染根 (通常加在 NSWindow 主 view 上), 让 dialog 脱离父级层级渲染.
    func hvmDialogHost() -> some View {
        modifier(HVMUI.DialogHostModifier())
    }
}

