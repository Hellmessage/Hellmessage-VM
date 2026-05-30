// HVMBorder.swift — 新 GUI 边框宽度 token. 业务侧禁硬数字, 走 HVMTheme.border.<name>.


import CoreGraphics

extension HVMTheme {
    enum border {
        static let hairline: CGFloat = 1
        static let focus:    CGFloat = 2
    }
}

