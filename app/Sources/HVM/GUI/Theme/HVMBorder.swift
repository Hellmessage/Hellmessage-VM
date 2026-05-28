// HVMBorder.swift — 新 GUI 边框宽度 token
//
// 业务侧禁止 .border(width: 1, ...) 硬数字, 一律走 HVMTheme.border.<name>
// + HVMTheme.color.borderDefault / borderFocus / borderError.

#if NEW_GUI

import CoreGraphics

extension HVMTheme {
    enum border {
        static let hairline: CGFloat = 1
        static let focus:    CGFloat = 2
    }
}

#endif
