// HVMUISection.swift — 新 GUI 卡片容器 (PR-C5)
//
// 业务页 layout 基石. 每节业务内容包进 Section 卡片, 有清晰边界 + R8 layered
// shadow + double border 给"飘起来"的精致感.
//
// 用法:
//   HVMUI.Section("基本信息") { content }
//   HVMUI.Section("网络", description: "vmnet daemon 控制") { content }
//   HVMUI.Section("确认配置") {
//       content
//   } footer: {
//       HStack {
//           HVMUI.Button("取消", variant: .secondary) { ... }
//           HVMUI.Button("保存", variant: .primary) { ... }
//       }
//   }
//   HVMUI.Section(variant: .elevated) { content }   // 无 title, Dialog 卡片风
//
// variant:
//   .default  — bgRaised 卡片底 + hairline border + 轻 shadow (业务 section)
//   .elevated — bgOverlay 抬一档 + double border (inner highlight + outer
//               borderEmphasis) + 重 shadow (Dialog / popover 卡片)
//
// 视觉细节 (Linear+ 精致化):
//   - 双层 border (R8): inner highlight (white α 0.04 top→clear 渐变, mock
//     "光从上洒下来" 效果) + outer hairline (borderDefault / borderEmphasis)
//   - layered shadow (R8): 主投影 (radius 12, y 6, 黑 α 0.3) + 近层投影
//     (radius 2, y 1, 黑 α 0.1), 给"轻轻浮起" 感
//   - 不裁 .clipShape (沿用 PR-C4 修复: 让内部 Select popover 等子组件
//     overlay 能浮出 Section 边界)
//
// 模块化 (R7): 一文件 = 一组件, footer 用 trailing closure label 让 API 自然.
// 没 footer 时用 EmptyView, Swift 类型推断处理.

#if NEW_GUI

import SwiftUI

extension HVMUI {

struct Section<Content: View, Footer: View>: View {
    enum Variant {
        case `default`
        case elevated
    }

    private let title: String?
    private let description: String?
    private let variant: Variant
    private let content: Content
    private let footer: Footer

    // 无 footer 便利 init
    init(_ title: String? = nil,
         description: String? = nil,
         variant: Variant = .default,
         @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.title = title
        self.description = description
        self.variant = variant
        self.content = content()
        self.footer = EmptyView()
    }

    // 带 footer init
    init(_ title: String? = nil,
         description: String? = nil,
         variant: Variant = .default,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.description = description
        self.variant = variant
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            if title != nil || description != nil {
                headerBlock
            }

            content

            if Footer.self != EmptyView.self {
                HVMUI.Divider(padding: .none)
                footer
            }
        }
        .padding(HVMTheme.space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        // 不 .clipShape — 允许内部 Select popover 等子组件 overlay 浮出边界
    }

    @ViewBuilder
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
            if let title {
                Text(title)
                    .font(HVMTheme.font.lg)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            if let description {
                Text(description)
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
            }
        }
    }

    /// 卡片背景层: fill + double border + layered shadow.
    /// 三个 modifier 组合给"飘起来"+"质感"+"精致"三层视觉.
    private var cardBackground: some View {
        ZStack {
            // 主 fill + outer border + 主 shadow
            RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                        .stroke(outerBorderColor, lineWidth: HVMTheme.border.hairline)
                )
                .shadow(color: .black.opacity(shadowMainAlpha),
                        radius: shadowMainRadius, x: 0, y: shadowMainY)
                .shadow(color: .black.opacity(shadowNearAlpha),
                        radius: shadowNearRadius, x: 0, y: shadowNearY)

            // Inner highlight: 顶部 1px 浅光 (R8 "光从上洒下" 效果, Linear 同款)
            RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                .stroke(
                    LinearGradient(
                        colors: [
                            HVMTheme.color.borderEmphasis,
                            HVMTheme.color.borderDefault.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: HVMTheme.border.hairline
                )
        }
        .allowsHitTesting(false)
    }

    private var fillColor: Color {
        switch variant {
        case .default:  return HVMTheme.color.bgRaised
        case .elevated: return HVMTheme.color.bgOverlay
        }
    }

    private var outerBorderColor: Color {
        switch variant {
        case .default:  return HVMTheme.color.borderDefault
        case .elevated: return HVMTheme.color.borderEmphasis
        }
    }

    // shadow 档: default 轻 / elevated 重
    private var shadowMainAlpha: Double {
        switch variant {
        case .default:  return 0.20
        case .elevated: return 0.40
        }
    }

    private var shadowMainRadius: CGFloat {
        switch variant {
        case .default:  return 8
        case .elevated: return 16
        }
    }

    private var shadowMainY: CGFloat {
        switch variant {
        case .default:  return 4
        case .elevated: return 8
        }
    }

    private var shadowNearAlpha: Double {
        switch variant {
        case .default:  return 0.08
        case .elevated: return 0.15
        }
    }

    private var shadowNearRadius: CGFloat {
        switch variant {
        case .default:  return 2
        case .elevated: return 4
        }
    }

    private var shadowNearY: CGFloat {
        switch variant {
        case .default:  return 1
        case .elevated: return 2
        }
    }
}

}  // extension HVMUI 结束

#endif
