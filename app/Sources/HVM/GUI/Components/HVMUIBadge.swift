// HVMUIBadge.swift — 新 GUI 状态徽标 (PR-C5)
//
// 用法:
//   HVMUI.Badge("Running", variant: .success)
//   HVMUI.Badge("Encrypted", icon: "lock.fill", variant: .accent, size: .sm)
//   HVMUI.Badge("Error", icon: "exclamationmark.triangle", variant: .error)
//   HVMUI.Badge("3", variant: .error, size: .sm)   // 数字徽标
//
// 6 variant (互斥):
//   .success — 绿 (VM running 等正常态)
//   .warn    — 黄 (vmnet daemon stale / 待重启等警告)
//   .error   — 红 (启动失败 / 加密失败 等)
//   .info    — 蓝 (普通信息)
//   .accent  — 青 (HVM 自家强调, 例 "Recommended" / "New")
//   .neutral — 灰 (中性, 例 OS 名 / Tag / count)
//
// 2 size:
//   .sm — 高 18, font xs (11), padding xs/sm, radius sm
//   .md — 高 22, font sm (12), padding sm/md, radius sm (default)
//
// 视觉: bg = variant 色 12% alpha (subtle, 不抢眼) + text = variant 色 full,
// 圆角 sm. 跟 Linear / Vercel 等 SaaS 风一致.


import SwiftUI

extension HVMUI {

struct Badge: View {
    enum Variant {
        case success, warn, error, info, accent, neutral
    }

    enum BadgeSize {
        case sm, md

        var height: CGFloat {
            switch self {
            case .sm: return 18
            case .md: return 22
            }
        }

        var font: Font {
            switch self {
            case .sm: return HVMTheme.font.xs
            case .md: return HVMTheme.font.sm
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .sm: return HVMTheme.space.sm
            case .md: return HVMTheme.space.md
            }
        }

        var iconSpacing: CGFloat {
            switch self {
            case .sm: return HVMTheme.space.xs
            case .md: return HVMTheme.space.xs
            }
        }
    }

    private let label: String
    private let icon: String?
    private let variant: Variant
    private let size: BadgeSize

    init(_ label: String,
         variant: Variant = .neutral,
         icon: String? = nil,
         size: BadgeSize = .md) {
        self.label = label
        self.icon = icon
        self.variant = variant
        self.size = size
    }

    var body: some View {
        HStack(spacing: size.iconSpacing) {
            if let icon {
                Image(systemName: icon)
                    .font(size.font)
            }
            Text(label)
                .font(size.font)
        }
        .foregroundStyle(fgColor)
        .padding(.horizontal, size.horizontalPadding)
        .frame(minHeight: size.height)
        .background(
            RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                .fill(bgColor)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var fgColor: Color {
        switch variant {
        case .success: return HVMTheme.color.success
        case .warn:    return HVMTheme.color.warn
        case .error:   return HVMTheme.color.error
        case .info:    return HVMTheme.color.info
        case .accent:  return HVMTheme.color.accent
        case .neutral: return HVMTheme.color.textSecondary
        }
    }

    /// bg = variant 色低 alpha (subtle), neutral 用 bgOverlay (中性灰底)
    private var bgColor: Color {
        switch variant {
        case .success: return HVMTheme.color.success.opacity(0.15)
        case .warn:    return HVMTheme.color.warn.opacity(0.15)
        case .error:   return HVMTheme.color.error.opacity(0.15)
        case .info:    return HVMTheme.color.info.opacity(0.15)
        case .accent:  return HVMTheme.color.accentMuted   // 已有 token, 等价 accent 15%
        case .neutral: return HVMTheme.color.bgOverlay
        }
    }
}

}  // extension HVMUI 结束

