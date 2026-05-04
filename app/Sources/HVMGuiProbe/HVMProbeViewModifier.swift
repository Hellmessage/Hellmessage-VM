// HVMGuiProbe/HVMProbeViewModifier.swift
// SwiftUI 控件注册到 ProbeRegistry 的 view modifier.
//
// 用法 (业务侧):
//   Button("Create") { doCreate() }
//       .hvmProbe(id: "dialog.createVM.button.create",
//                 label: "Create",
//                 action: .button { doCreate() })
//
// 注: action closure 必须跟原 onTap 等价 (业务侧重复, 避免 SwiftUI 提取 Button.action).
// SwiftUI Button.action 是 internal, 我们没法反射, 所以让业务侧重写一次. 一个 lint 规则就够.

import SwiftUI

public extension View {
    /// 给当前 view 打 hvm-probe id + action. onAppear 注册到 ProbeRegistry, onDisappear 移除.
    /// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md PR-G2.
    func hvmProbe(id: String,
                   label: String = "",
                   action: ProbeAction) -> some View {
        self.modifier(HVMProbeModifier(identifier: id, label: label, action: action))
    }
}

private struct HVMProbeModifier: ViewModifier {
    let identifier: String
    let label: String
    let action: ProbeAction

    func body(content: Content) -> some View {
        content
            .onAppear {
                ProbeRegistry.register(ProbeItem(identifier: identifier,
                                                  label: label,
                                                  action: action))
            }
            .onDisappear {
                ProbeRegistry.unregister(identifier)
            }
    }
}
