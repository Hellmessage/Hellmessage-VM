// HVMMotion.swift — 新 GUI 动效时长 + 曲线 token
//
// 业务侧禁止 .animation(.easeOut(duration: 0.2)) 硬写, 一律走 HVMTheme.motion.<name>.
// 时长档位 fast (120ms hover/press) / base (200ms 字段 focus / Dialog 进出) /
// slow (320ms 切页 / Wizard 步骤). spring 仅按钮 press 反馈.

#if NEW_GUI

import SwiftUI

extension HVMTheme {
    enum motion {
        static let fast: Double = 0.12
        static let base: Double = 0.20
        static let slow: Double = 0.32

        static let easeOut     = Animation.easeOut(duration: base)
        static let easeIn      = Animation.easeIn(duration: base)
        static let easeOutFast = Animation.easeOut(duration: fast)
        static let easeOutSlow = Animation.easeOut(duration: slow)

        /// 按钮 press 反馈, 业务侧不直接用
        static let pressSpring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    }
}

#endif
