// HVMGuiProbe/HVMProbeViewModifier.swift
// SwiftUI 控件注册到 ProbeRegistry 的 view modifier.
//
// action closure 必须跟原 onTap 等价 (SwiftUI Button.action 是 internal 无法反射, 业务侧重写一次).

import SwiftUI

public extension View {
    /// 给当前 view 打 hvm-probe id + action. onAppear 注册到 ProbeRegistry, onDisappear 移除.
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
