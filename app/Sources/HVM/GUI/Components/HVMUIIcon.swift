// HVMUIIcon.swift — 新 GUI SF Symbol 包装.
//
// 5 size: .xs 10pt / .sm 12pt / .md 14pt (default) / .lg 18pt / .xl 24pt.
// color: 6 语义色 (success/warn/error/info/accent/neutral) + .primary/.secondary/.tertiary.
// SF Symbol weight = .medium.
// 用法: HVMUI.Icon("trash") / HVMUI.Icon("checkmark", size: .sm, color: .success)


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
            .accessibilityHidden(true)   // 装饰 icon, 不重复朗读
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

