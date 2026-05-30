// HVMMotion.swift — 新 GUI 动效时长 + 曲线 token. 业务侧禁硬写 duration, 走 HVMTheme.motion.<name>.
// fast (120ms hover/press) / base (200ms focus / Dialog) / slow (320ms 切页); spring 仅按钮 press.


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

