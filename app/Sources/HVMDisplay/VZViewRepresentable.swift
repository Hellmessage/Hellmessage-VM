// VZViewRepresentable.swift
// SwiftUI 包装. 嵌入态/独立窗口复用同一个 HVMView 实例, 在窗口间 reparent.
// 详见 docs/DISPLAY_INPUT.md "窗口容器"

import SwiftUI
import AppKit
@preconcurrency import Virtualization

public struct VZViewRepresentable: NSViewRepresentable {
    private let view: HVMView

    public init(view: HVMView) {
        self.view = view
    }

    public func makeNSView(context: Context) -> HVMView {
        view
    }

    public func updateNSView(_ nsView: HVMView, context: Context) {
        // 复用同一实例, updateNSView 无需变更
    }
}
