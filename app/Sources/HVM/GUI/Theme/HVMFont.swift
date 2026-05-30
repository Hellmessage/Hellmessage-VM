// HVMFont.swift — 新 GUI 字号 token (Linear 风, 严格节奏)
//
// 业务侧禁止 Font.system(size:...) 直写, 一律走 HVMTheme.font.<name>.
// 节奏: 11 / 12 / 13 / 14 / 18 / 24, 不留中间值 (16 / 20 等).
// mono 仅用于"代码值" (UUID / MAC / 路径 / shell 命令展示 / build 号).


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

