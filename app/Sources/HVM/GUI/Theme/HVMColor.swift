// HVMColor.swift — 新 GUI 色板 token (Linear 风, 固定深色)
//
// 业务侧禁止 Color(red:..., green:..., blue:...) 或 Color(hex:...) 直写,
// 一律走 HVMTheme.color.<name>. 防漂移 lint script (PR-L1) 会扫整个 GUI/ 拦.
//
// accent: 青 #06B6D4 (D1 已决 2026-05-28).
//
// 嵌进 HVMTheme namespace, 避免跟老 GUI 顶层 `public enum HVMColor`
// (UI/Style/Theme.swift) 撞名.


import SwiftUI

extension HVMTheme {
    enum color {
        // 背景层 (z 从深到浅 — base 是主底, overlay 是 Dialog 卡片)
        static let bgBase    = Color(hex: 0x08090A)
        static let bgRaised  = Color(hex: 0x101113)
        static let bgOverlay = Color(hex: 0x18191B)
        static let bgHover   = Color(hex: 0xFFFFFF, alpha: 0.04)

        // 文字
        static let textPrimary   = Color(hex: 0xF7F8F8)
        static let textSecondary = Color(hex: 0x8A8F98)
        static let textTertiary  = Color(hex: 0x62666D)
        static let textOnAccent  = Color(hex: 0xFFFFFF)

        // 边框
        static let borderDefault  = Color(hex: 0xFFFFFF, alpha: 0.08)
        // borderEmphasis: 比 borderDefault 强一档, 给在 sectionCard (bgRaised) 内嵌入
        // 的控件 (Toggle / Checkbox off 态) 用 — 普通 borderDefault 在 bgRaised 上
        // 太弱 (0.08), 跟卡片 bg 同色容器轮廓出不来
        static let borderEmphasis = Color(hex: 0xFFFFFF, alpha: 0.16)
        static let borderFocus    = Color(hex: 0x06B6D4, alpha: 0.6)
        static let borderError    = Color(hex: 0xEF4444, alpha: 0.6)

        // accent (青)
        static let accent       = Color(hex: 0x06B6D4)
        static let accentHover  = Color(hex: 0x0891B2)
        static let accentMuted  = Color(hex: 0x06B6D4, alpha: 0.15)

        // 状态色
        static let success = Color(hex: 0x10B981)
        static let warn    = Color(hex: 0xF59E0B)
        static let error   = Color(hex: 0xEF4444)
        static let info    = Color(hex: 0x3B82F6)

        // destructive 按钮 hover bg (error 12% 红, 跟 borderError 配套)
        static let destructiveHover = Color(hex: 0xEF4444, alpha: 0.12)

        // 透明 (按钮 / 字段 ghost 态 bg; 业务侧禁止直写 Color.clear)
        static let transparent = Color.clear

        // disabled 控件 bg — 比 bgRaised 亮一档, 在 bgBase 主底上有清晰轮廓.
        // Toggle / Checkbox / 其他控件 disabled 时改用这个 bg 而不是单纯 opacity 0.4
        // (深色 GUI 上整体降透会让控件跟底色压成一片, 看不出形). 配合 textTertiary 文字
        // 和圆点形成"低对比但可读"的 disabled 态.
        static let bgDisabled = Color(hex: 0x2A2B2E)
    }
}

/// Color hex 初始化扩展. fileprivate 锁在本文件 — 业务侧禁止用.
extension Color {
    fileprivate init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}

