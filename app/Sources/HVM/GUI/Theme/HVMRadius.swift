// HVMRadius.swift — 新 GUI 圆角 token (Linear 风)
//
// 业务侧禁止 .cornerRadius(8) 硬数字, 一律走 HVMTheme.radius.<name>.
// 档位: sm (小按钮/badge) → md (普通按钮/字段) → lg (Section card) → xl (Dialog).

#if NEW_GUI

import CoreGraphics

extension HVMTheme {
    enum radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
    }
}

#endif
