// HVMRadius.swift — 新 GUI 圆角 token. 业务侧禁硬数字, 走 HVMTheme.radius.<name>.
// 档位: sm (badge) / md (按钮/字段) / lg (Section card) / xl (Dialog).


import CoreGraphics

extension HVMTheme {
    enum radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
    }
}

