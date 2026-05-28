// HVMUIIcon.swift — 新 GUI SF Symbol 包装 (PR-C6)
//
// 用法:
//   HVMUI.Icon("trash")                              // .md default
//   HVMUI.Icon("lock.fill", size: .lg)
//   HVMUI.Icon("checkmark", size: .sm, color: .success)
//   HVMUI.Icon("exclamationmark.triangle", color: .warn)
//
// size:
//   .xs — 10pt (微小, badge / inline)
//   .sm — 12pt (字段 leading / kbd hint)
//   .md — 14pt (default, button / 普通 icon)
//   .lg — 18pt (section header / hero)
//   .xl — 24pt (空状态插图 / hero)
//
// color: 6 个语义色 (success/warn/error/info/accent/neutral) + .primary/.secondary
//   - 默认 .primary (textPrimary 白)
//   - .secondary (textSecondary 灰, 给次要 icon 用)
//   - 6 语义色对应 Theme color (跟 Badge variant 一致)
//
// SF Symbol 默认 weight = .medium (Linear / Vercel 同款 stroke icon 风),
// 不用 .regular (太细) 也不用 .bold (太粗).

#if NEW_GUI

import SwiftUI

extension HVMUI {

struct Icon: View {
    enum IconSize {
        case xs, sm, md, lg, xl

        var pointSize: CGFloat {
            switch self {
            case .xs: return 10
            case .sm: return 12
            case .md: return 14
            case .lg: return 18
            case .xl: return 24
            }
        }

        var font: Font {
            Font.system(size: pointSize, weight: .medium)
        }
    }

    enum IconColor {
        case primary, secondary, tertiary
        case success, warn, error, info, accent, neutral
    }

    private let symbol: String
    private let size: IconSize
    private let color: IconColor

    init(_ symbol: String,
         size: IconSize = .md,
         color: IconColor = .primary) {
        self.symbol = symbol
        self.size = size
        self.color = color
    }

    var body: some View {
        Image(systemName: symbol)
            .font(size.font)
            .foregroundStyle(fgColor)
            .accessibilityHidden(true)   // 装饰 icon 跟 label 一起朗读, 不重复
    }

    private var fgColor: Color {
        switch color {
        case .primary:   return HVMTheme.color.textPrimary
        case .secondary: return HVMTheme.color.textSecondary
        case .tertiary:  return HVMTheme.color.textTertiary
        case .success:   return HVMTheme.color.success
        case .warn:      return HVMTheme.color.warn
        case .error:     return HVMTheme.color.error
        case .info:      return HVMTheme.color.info
        case .accent:    return HVMTheme.color.accent
        case .neutral:   return HVMTheme.color.textSecondary
        }
    }
}

}  // extension HVMUI 结束

#endif
