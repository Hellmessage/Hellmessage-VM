// HVMFont.swift — 新 GUI 字号 token. 业务侧禁 Font.system(size:) 直写, 走 HVMTheme.font.<name>.
// 节奏严格 11/12/13/14/18/24, 不留中间值. mono 仅用于代码值 (UUID/MAC/路径/build 号).


import SwiftUI

extension HVMTheme {
    enum font {
        static let xs   = Font.system(size: 11, weight: .regular)
        static let sm   = Font.system(size: 12, weight: .regular)
        static let base = Font.system(size: 13, weight: .regular)
        static let md   = Font.system(size: 14, weight: .medium)
        static let lg   = Font.system(size: 18, weight: .semibold)
        static let xl   = Font.system(size: 24, weight: .semibold)

        static let mono   = Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoSm = Font.system(size: 12, weight: .regular, design: .monospaced)
    }
}

