// HVMUIDialogHost.swift — 新 GUI 全局浮窗容器 (PR-D1)
//
// 解决问题: 之前 Select popover / Tooltip 等浮窗用 trigger.overlay() 渲染, 受
// 父容器层级影响:
//   - ScrollView clip 限制 — popover 超 ScrollView 边界被裁
//   - sectionCard border overlay — border 画在 popover 之上
//   - VStack sibling 渲染顺序 — 后画的 sectionCard 压在 popover 之上
// 之前用 zIndex 反向 hack 治标, popover 仍受 ScrollView clip 限制.
//
// 方案: 根视图加 .hvmDialogHost() modifier, 内部 ZStack 渲染层在所有 ScrollView /
// sectionCard / VStack 层级之外, 浮窗完全脱离父级限制. 业务侧通过
// @Environment(\.hvmDialog) 调 .present { ... } 提交浮窗内容到 root-level ZStack.
//
// 用法 (业务侧):
//   @Environment(\.hvmDialog) var dialog
//
//   HVMUI.Button("打开", probeID: "...") {
//       dialog.present { handle in
//           VStack {
//               Text("Hello!")
//               HVMUI.Button("关闭", probeID: "...") { handle.close() }
//           }
//           .padding(HVMTheme.space.xl)
//           .background(...)
//       }
//   }
//
// 根视图接入 (在创建 NSHostingController 时套外层):
//   let host = NSHostingController(rootView: NewGUIRootView().hvmDialogHost())
//
// 关键: .hvmDialogHost() 必须套在 NSHostingController 的 rootView 外层, 让它
// 是 NewGUIRootView 的真正祖先. 这样 NewGUIRootView 内部可直接
// @EnvironmentObject 拿到 DialogPresenter. 如果加在 NewGUIRootView body 末尾
// 那是子层 modifier 应用对象, NewGUIRootView 自身评估时 environment 还没注入,
// 会触发 fatal "No ObservableObject of type DialogPresenter found".
//
// 多 dialog 栈: 支持嵌套 present (例 Wizard 内再开 Confirm "确定取消?"),
// 栈顶 dialog 接收交互. 业务侧用 handle.close() 关栈顶, presenter.dismissAll()
// 一次性关全部.
//
// 蒙底 (backdrop): bgBase 60% opacity, **不可点关** (CLAUDE.md GUI 约束: 弹窗
// 只能通过点击右上角 X 按钮关闭).
//
// 后续 (PR-D2~D7):
// - D2 FocusTrap + EscRouter (Tab 锁卡片内, Esc 关栈顶)
// - D3 HVMUI.AlertDialog 接入 (info/warn/error/success)
// - D4 HVMUI.ConfirmDialog
// - D5 HVMUI.InputDialog
// - D6 HVMUI.WizardDialog
// - Select popover 迁移到 OverlayContainer (清掉 zIndex 反向 hack)

#if NEW_GUI

import SwiftUI

extension HVMUI {

/// 全局浮窗管理器. SwiftUI @Observable 单例 per Host, 通过 EnvironmentValue 注入.
/// 用 ObservableObject 而不是 @Observable — macOS 14 SwiftUI 上 @Observable 配
/// @Environment(\.hvmDialog) 注入时 subscribe 时序不稳定, ObservableObject +
/// @StateObject + @EnvironmentObject 老 API 更可靠.
@MainActor
final class DialogPresenter: ObservableObject {
    /// 当前显示的 dialog 栈 (栈顶在 last). 多 dialog 嵌套时按入栈顺序渲染.
    @Published fileprivate var stack: [DialogEntry] = []

    /// nonisolated init: 让 default 实例能在 nonisolated context 初始化.
    /// mutation (present/dismiss) 仍只能在 MainActor 上.
    nonisolated init() {}

    /// 推一个浮窗到栈顶. content closure 接收 DialogHandle, 业务侧用它关闭自己.
    /// 返回 handle, 让外部也能控制关闭 (例如 Task.cancellation).
    ///
    /// onDismiss: dialog 关闭后回调 — 不论关闭路径 (X 按钮 / 主按钮 / Esc /
    /// presenter.dismissAll), 都会触发一次. async API (例 .alert) 用它把
    /// CheckedContinuation.resume() 接进所有关闭路径, 防业务 await 永远卡住.
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

/// 根视图 ViewModifier — 把 dialog 渲染到 root-level ZStack, 脱离父级 ScrollView /
/// sectionCard / VStack 层级.
///
/// PR-D2 加入交互层:
/// - **FocusTrap**: dialog 显示时 .disabled(true) 背景 content, 让背景 focusable
///   views (button/textfield 等) 失活, Tab 自然循环锁在 dialog 内 (SwiftUI 内置
///   focus 不会跑到 disabled view)
/// - **EscRouter**: dialog 渲染层 .focusable() + .onKeyPress(.escape) 关栈顶
///   dialog. 没 dialog 时不拦 Esc, 透给业务 (例如 framebuffer 接 Esc 给 guest)
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
                    // 嵌套 dialog 关一层后, 外层仍在, 主动 re-focus 让下次 Esc 仍能关
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
                // 显式高 zIndex 确保 dialog 永远浮在 content 内任何高 zIndex
                // view (Tooltip .zIndex(2000) / Select popover .zIndex(1000) /
                // 业务页未来可能加的高 zIndex) 之上.
                // 注: 不用 .greatestFiniteMagnitude (1.8e308) — SwiftUI 浮点
                // 比较算法在跟其他 view 高 zIndex 共存时不稳定, dialog 会消失.
                // 999_999 实际超过所有可能业务 zIndex.
                .zIndex(999_999)
            }
        }
        .animation(HVMTheme.motion.easeOut, value: presenter.stack.count)
    }
}

}  // extension HVMUI 结束

// 业务侧用 @EnvironmentObject private var dialog: HVMUI.DialogPresenter
// (ObservableObject 路径, 不是 @Entry @Environment).
//
// 没有 @Entry EnvironmentValues 注入 — DialogHostModifier 内 .environmentObject
// 给 content 注入, 子 view 用 @EnvironmentObject 拿到.

extension View {
    /// 把当前 view 设为 dialog 渲染根 (通常加在 NSWindow 主 view 上).
    /// 内部 ZStack 让 dialog 在所有 ScrollView / sectionCard / VStack 层级之外
    /// 渲染, 不受父级 clip / border / 渲染顺序影响.
    func hvmDialogHost() -> some View {
        modifier(HVMUI.DialogHostModifier())
    }
}

#endif
