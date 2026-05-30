// HVMUISection.swift — 新 GUI 卡片容器. 业务页每节内容包进 Section 卡片.
//
// 2 variant: .default (bgRaised + hairline + 轻 shadow, 业务 section) /
//            .elevated (bgOverlay + double border + 重 shadow, Dialog / popover).
// 视觉: 双层 border (inner highlight + outer) + layered shadow; 不裁 .clipShape
//       (让内部 Select popover 等 overlay 浮出边界).
// 用法: HVMUI.Section("基本信息") { content }, 可带 description / headerTrailing / footer.


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
    /// 标题行右侧 accessory (例 "添加数据盘" 亮色按钮). 类型擦除避免泛型爆炸 (低频).
    private let headerTrailing: AnyView?

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
        self.headerTrailing = nil
    }

    // 带 headerTrailing init (标题右侧放按钮等)
    init<HT: View>(_ title: String? = nil,
                   description: String? = nil,
                   variant: Variant = .default,
                   @ViewBuilder headerTrailing: () -> HT,
                   @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.title = title
        self.description = description
        self.variant = variant
        self.content = content()
        self.footer = EmptyView()
        self.headerTrailing = AnyView(headerTrailing())
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
        self.headerTrailing = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            if title != nil || description != nil || headerTrailing != nil {
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
        HStack(alignment: .center, spacing: HVMTheme.space.md) {
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
            if let headerTrailing {
                Spacer(minLength: HVMTheme.space.sm)
                headerTrailing
            }
        }
    }

    /// 卡片背景层: fill + double border + layered shadow.
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

            // Inner highlight: 顶部 1px 浅光 ("光从上洒下" 效果)
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

