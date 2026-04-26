// HVMToggle.swift
// 自绘开关. 苹果胶囊滑块语汇:
//   - 关: 灰轨 + 白圆点居左
//   - 开: 蓝轨 + 白圆点居右
//   - 尺寸 36x20, 圆点 16
// 不依赖 SwiftUI Toggle, 完全自绘.
//
// 用法:
//   HVMToggle("Boot from disk only", isOn: $bootFromDisk)
//   HVMToggle("启用 USB", isOn: $usb, help: "重启后生效")
//
// 强制约束 (CLAUDE.md): 业务代码禁止直接用 SwiftUI Toggle.

import SwiftUI

public struct HVMToggle: View {
    private let label: String?
    @Binding private var isOn: Bool
    private let help: String?
    private let disabled: Bool

    public init(
        _ label: String? = nil,
        isOn: Binding<Bool>,
        help: String? = nil,
        disabled: Bool = false
    ) {
        self.label = label
        self._isOn = isOn
        self.help = help
        self.disabled = disabled
    }

    public var body: some View {
        HStack(spacing: HVMSpace.md) {
            if let label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(HVMFont.body)
                        .foregroundStyle(disabled ? HVMColor.textTertiary : HVMColor.textPrimary)
                    if let help {
                        Text(help)
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: HVMSpace.md)
            }
            switchBody
        }
        .opacity(disabled ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "开关")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isButton)
    }

    private var switchBody: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? HVMColor.accent : Color.white.opacity(0.18))
            Circle()
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .padding(2)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .frame(width: 36, height: 20)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isOn)
    }

    private func toggle() {
        guard !disabled else { return }
        isOn.toggle()
    }
}
