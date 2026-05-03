// HVMCard.swift
// 业务侧 "圆角卡片 + 1px 边框" 组合 ViewModifier. 之前 DetailBars / Settings 等多处复制粘贴
// `.background(RoundedRectangle.fill(...)).overlay(RoundedRectangle.stroke(...))`
// 五段, 圆角值 / 描边色 / 不透明度容易漂移. 统一收口到 .hvmCard().

import SwiftUI

public extension View {
    /// 标准卡片背景: 圆角 fill + 1px stroke. 默认走 HVMColor.bgCard + HVMColor.border + HVMRadius.md.
    func hvmCard(
        radius: CGFloat = HVMRadius.md,
        fill: Color = HVMColor.bgCard,
        stroke: Color = HVMColor.border,
        strokeWidth: CGFloat = 1
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: strokeWidth)
            )
    }
}
