// HVMSpace.swift — 新 GUI 间距 token (Linear 风, 4-pt grid)
//
// 业务侧禁止 .padding(8) 硬数字, 一律走 HVMTheme.space.<name>.

#if NEW_GUI

import CoreGraphics

extension HVMTheme {
    enum space {
        static let xs:   CGFloat = 4
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let xl:   CGFloat = 24
        static let xxl:  CGFloat = 32
        static let xxxl: CGFloat = 48
    }
}

#endif
