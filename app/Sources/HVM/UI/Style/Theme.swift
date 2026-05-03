// Theme.swift
// 风格 token 统一入口. 当前主题: VMware / Parallels 专业工具风
//   - 中性深灰底 (非纯黑), 减疲劳
//   - SF Pro 主导, mono 仅用于 ID / MAC / 路径 / 命令值
//   - 单一蓝 accent #4D9DFF, 无 glow / 无大幅 tracking
//   - 圆角 8/10/12, 1px 细边 + 黑色低 alpha 阴影
//
// 关键约束: 所有 HVMColor / HVMFont / HVMSpace / HVMRadius API 名不变,
// 仅改取值; 旧业务代码引用 HVMColor.accent 等仍可继续用, 视觉自动跟随.

import SwiftUI

public enum HVMColor {
    // MARK: - 背景三层 (从外到内)
    /// 主底 — 偏冷的中性深灰, 不刺眼
    public static let bgBase       = Color(red: 0.094, green: 0.094, blue: 0.106)   // #18181B
    /// 侧栏 / 二级容器
    public static let bgSidebar    = Color(red: 0.122, green: 0.125, blue: 0.141)   // #1F2024
    /// 卡片底
    public static let bgCard       = Color(red: 0.149, green: 0.153, blue: 0.169)   // #26272B
    /// 卡片次高 (输入框 / 嵌入元素)
    public static let bgCardHi     = Color(red: 0.176, green: 0.180, blue: 0.196)   // #2D2E32
    /// 浮起容器 (modal / popover)
    public static let bgElevated   = Color(red: 0.200, green: 0.204, blue: 0.220)   // #333438
    /// hover 半透明
    public static let bgHover      = Color.white.opacity(0.05)
    /// 选中态半透明 (蓝色低 alpha)
    public static let bgSelected   = Color(red: 0.302, green: 0.616, blue: 1.000).opacity(0.12)

    // MARK: - 边框
    public static let border       = Color.white.opacity(0.10)
    public static let borderStrong = Color.white.opacity(0.18)
    public static let borderAccent = Color(red: 0.302, green: 0.616, blue: 1.000).opacity(0.65)

    // MARK: - 文字
    public static let textPrimary   = Color(red: 0.93, green: 0.94, blue: 0.95)
    public static let textSecondary = Color(red: 0.63, green: 0.65, blue: 0.69)
    public static let textTertiary  = Color(red: 0.43, green: 0.45, blue: 0.49)
    public static let textOnAccent  = Color.white

    // MARK: - Accent (专业蓝)
    public static let accent       = Color(red: 0.302, green: 0.616, blue: 1.000)   // #4D9DFF
    public static let accentHover  = Color(red: 0.420, green: 0.690, blue: 1.000)
    public static let accentMuted  = Color(red: 0.302, green: 0.616, blue: 1.000).opacity(0.18)

    // MARK: - 状态色 (苹果系统风)
    public static let statusRunning = Color(red: 0.204, green: 0.780, blue: 0.349)  // #34C759
    public static let statusStopped = Color(red: 0.55, green: 0.57, blue: 0.61)
    public static let statusPaused  = Color(red: 1.00, green: 0.745, blue: 0.176)   // #FFBE2D
    public static let statusError   = Color(red: 1.00, green: 0.271, blue: 0.227)   // #FF453A

    public static let danger       = Color(red: 1.00, green: 0.271, blue: 0.227)   // #FF453A

    // MARK: - 资源系列 tint (stat icon)
    public static let statCPU     = Color(red: 0.302, green: 0.616, blue: 1.000)    // 蓝
    public static let statMemory  = Color(red: 0.690, green: 0.510, blue: 1.000)    // 紫
    public static let statDisk    = Color(red: 1.000, green: 0.745, blue: 0.176)    // 琥珀
    public static let statNetwork = Color(red: 0.204, green: 0.780, blue: 0.349)    // 绿

    // Guest OS 配色 (CreateVMDialog / GuestIcon 用)
    public static let guestLinuxAccent   = Color(red: 0.95, green: 0.65, blue: 0.20)  // 暖橙
    public static let guestMacOSAccent   = Color(red: 0.85, green: 0.88, blue: 0.94)  // 银白
    public static let guestWindowsAccent = Color(red: 0.302, green: 0.616, blue: 1.00) // 蓝 (= accent)

    // Detached 窗口 macOS 风红黄绿圆按钮配色
    public static let windowClose = Color(red: 1.00, green: 0.37, blue: 0.36)
    public static let windowMin   = Color(red: 1.00, green: 0.74, blue: 0.18)
    public static let windowZoom  = Color(red: 0.16, green: 0.79, blue: 0.27)
}

public enum HVMSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    // Button vertical padding (Buttons.swift 五种 ButtonStyle 用; 命名跟 size 走避免漂移)
    public static let buttonPadV5: CGFloat  = 5
    public static let buttonPadV6: CGFloat  = 6
    public static let buttonPadV7: CGFloat  = 7
    public static let buttonPadV10: CGFloat = 10

    // Row vertical padding (DetailBars 详情行 / Settings list row)
    public static let rowV9: CGFloat  = 9
    public static let rowV12: CGFloat = 12

    // 微间距 (badge inner, dropdown chip 等)
    public static let v2: CGFloat = 2

    // Popover / Toolbar 专用 (MenuPopoverView / Toolbar)
    public static let popoverH14: CGFloat = 14
    public static let popoverV28: CGFloat = 28
}

public enum HVMRadius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 12
    public static let pill: CGFloat = 999
}

public enum HVMBar {
    public static let toolbarHeight: CGFloat   = 48
    public static let statusBarHeight: CGFloat = 28
}

/// 主窗口尺寸. 用户日常想调主窗口大小直接改这里.
public enum HVMWindow {
    public static let mainDefault   = CGSize(width: 1200, height: 1090)
    public static let mainMin       = CGSize(width: 1020, height: 640)
    public static let mainStopped   = CGSize(width: 1080, height: 720)
}

/// 字体. 主语言 SF Pro, mono 限定值 (路径 / ID / MAC / 命令)
public enum HVMFont {
    // proportional (主导)
    public static let display = Font.system(size: 38, weight: .light)        // 大数字 (DetailBars 空状态)
    public static let bigRegular = Font.system(size: 22)                     // MenuPopoverView 顶部 emoji
    public static let hero    = Font.system(size: 22, weight: .semibold)
    public static let title   = Font.system(size: 16, weight: .semibold)
    public static let headingBold    = Font.system(size: 14, weight: .bold)
    public static let heading        = Font.system(size: 14, weight: .semibold)
    public static let headingRegular = Font.system(size: 14)
    public static let body          = Font.system(size: 13)
    public static let bodyMedium    = Font.system(size: 13, weight: .medium)
    public static let bodyBold      = Font.system(size: 13, weight: .semibold)
    public static let caption       = Font.system(size: 12)
    public static let captionMedium = Font.system(size: 12, weight: .medium)
    public static let captionEm     = Font.system(size: 12, weight: .semibold)
    public static let captionBold   = Font.system(size: 12, weight: .bold)
    public static let small         = Font.system(size: 11)
    public static let smallEm       = Font.system(size: 11, weight: .semibold)
    public static let smallBold     = Font.system(size: 11, weight: .bold)
    public static let tiny          = Font.system(size: 10)
    public static let label         = Font.system(size: 10, weight: .semibold)
    public static let micro         = Font.system(size: 9)
    public static let microEm       = Font.system(size: 9, weight: .semibold)
    public static let microBold     = Font.system(size: 8, weight: .bold)
    public static let statValue     = Font.system(size: 22, weight: .semibold)

    // mono (仅用于 ID / 路径 / MAC / 命令值)
    public static let mono       = Font.system(size: 12, design: .monospaced)
    public static let monoSmall  = Font.system(size: 11, design: .monospaced)
    public static let monoBody   = Font.system(size: 13, weight: .bold, design: .monospaced)  // MenuPopover banner
}

/// 小型 section 标签 (例: "Resources" / "General").
/// 不再大写 + tracking, 普通句首大写.
public struct LabelText: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = HVMColor.textSecondary) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text)
            .font(HVMFont.label)
            .foregroundStyle(color)
    }
}

/// 网络模式分段控件 (NAT / Bridged / Shared 这类水平 segmented).
/// 选中: 蓝色描边 + 蓝色字; 未选中: 中灰边 + 次级文字.
public struct HVMNetModeSegment: View {
    public let label: String
    public let selected: Bool
    public let disabled: Bool

    public init(_ label: String, selected: Bool, disabled: Bool = false) {
        self.label = label
        self.selected = selected
        self.disabled = disabled
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, HVMSpace.sm)
            .foregroundStyle(disabled
                ? HVMColor.textTertiary
                : (selected ? HVMColor.accent : HVMColor.textSecondary))
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(selected ? HVMColor.bgSelected : HVMColor.bgCardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .stroke(selected ? HVMColor.borderAccent : HVMColor.border, lineWidth: 1)
            )
            .opacity(disabled ? 0.45 : 1.0)
    }
}

/// 与 HVMTextField 同视觉的 menu 形 picker 外框, 给 SwiftUI 原生 Picker 套皮用.
/// 注意: 业务代码应优先使用 HVMFormSelect, 这里只为兼容少数无法替换的场景保留.
public struct HVMFormMenuField<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .font(HVMFont.body)
            .tint(HVMColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(HVMColor.bgCardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
    }
}

/// 自绘下拉框. 触发后选项列表挂到 NSPanel attached child window 浮起,
/// 紧贴 trigger 下边缘. 不在 SwiftUI 视图树, 因此不撑大父容器、不被 ScrollView/clipShape 裁掉.
/// 视觉与 HVMTextField / HVMFormMenuField 同源 (圆角 8 / bgCardHi / border).
///
/// 定位策略: 通过 .background 挂一个 1×1 不可见 NSView 作为 anchor, popup 时直接拿
/// anchor 的 window/screen frame, 不依赖 SwiftUI .frame(in: .global) (在嵌套 NSHostingView
/// 场景下偏移).
public struct HVMFormSelect: View {
    public let options: [(value: String, label: String)]
    @Binding public var selection: String
    /// 无障碍读名
    public var accessibilityLabel: String

    @State private var isOpen: Bool = false
    /// anchor NSView 的引用持有者 (HVMAnchorView 在 makeNSView 时填入)
    @StateObject private var anchorRef = AnchorRef()
    /// NSPanel controller 用引用类型 wrapper 持久化, 避免 SwiftUI value-state 重置丢实例
    @StateObject private var holder = PopupHolder()

    public init(
        options: [(value: String, label: String)],
        selection: Binding<String>,
        accessibilityLabel: String = "选择"
    ) {
        self.options = options
        self._selection = selection
        self.accessibilityLabel = accessibilityLabel
    }

    private var currentLabel: String {
        if let f = options.first(where: { $0.value == selection }) {
            return f.label
        }
        return selection
    }

    public var body: some View {
        Button {
            if isOpen { dismissPopup() } else { presentPopup() }
        } label: {
            HStack(spacing: HVMSpace.sm) {
                Text(currentLabel)
                    .font(HVMFont.body)
                    .foregroundStyle(HVMColor.textPrimary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .fill(HVMColor.bgCardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                    .stroke(isOpen ? HVMColor.borderAccent : HVMColor.border,
                            lineWidth: isOpen ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .background(HVMAnchorView(ref: anchorRef.holder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(currentLabel)
        .onDisappear { dismissPopup() }
    }

    private func presentPopup() {
        guard let anchor = anchorRef.holder.view else { return }
        isOpen = true
        holder.panel.present(
            anchor: anchor,
            maxHeight: 240,
            content: { popupBody }
        ) {
            isOpen = false
        }
    }

    private func dismissPopup() {
        holder.panel.dismiss()
    }

    /// popup 内容. 行高紧凑 (vertical 4), 选中态仅蓝字 + checkmark, 无大块底色.
    @ViewBuilder
    private var popupBody: some View {
        let chosen = selection
        ScrollView {
            VStack(spacing: 1) {
                ForEach(options, id: \.value) { opt in
                    PopupRow(
                        label: opt.label,
                        isSelected: chosen == opt.value,
                        onTap: {
                            selection = opt.value
                            holder.panel.dismiss()
                        }
                    )
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 240)
        .background(HVMColor.bgElevated)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(HVMColor.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous))
    }
}

/// HVMFormSelect 内部 row, 拆出来是为了独立持有 hover state, 不污染外层 @State.
private struct PopupRow: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hover: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HVMSpace.sm) {
                Text(label)
                    .font(HVMFont.caption)
                    .foregroundStyle(isSelected ? HVMColor.accent : HVMColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(HVMColor.accent)
                }
            }
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(hover ? HVMColor.bgHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// NSPanel controller 引用 holder, 保 SwiftUI 重新计算 body 时 panel 实例不丢
@MainActor
private final class PopupHolder: ObservableObject {
    let panel = HVMPopupPanel()
}

/// HVMAnchorView 的 weak ref 持有者. SwiftUI @StateObject 持有, view 销毁时一起销.
@MainActor
private final class AnchorRef: ObservableObject {
    let holder = HVMAnchorView.Holder()
}

/// running 状态脉冲点 (绿色, 不带 glow).
public struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @State private var animating = false

    public init(color: Color = HVMColor.statusRunning, size: CGFloat = 6) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.30))
                .frame(width: size * 2.4, height: size * 2.4)
                .scaleEffect(animating ? 1.15 : 0.85)
                .opacity(animating ? 0 : 1)
                .animation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: animating
                )
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.6, height: size * 2.6)
        .onAppear { animating = true }
    }
}

/// 通用分组卡片 (取代旧的 TerminalSection ┌─ ──┐ 终端框).
/// 标题左对齐, 字号 13/semibold, 内容包在卡片里 (圆角 + 1px 边).
/// 名字保留 TerminalSection 是为兼容现有 callsite, 视觉已重做.
public struct TerminalSection<Content: View>: View {
    let title: String
    let trailing: AnyView?
    let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = nil
        self.content = content
    }

    public init<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = AnyView(trailing())
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            HStack(spacing: HVMSpace.sm) {
                Text(title)
                    .font(HVMFont.heading)
                    .foregroundStyle(HVMColor.textPrimary)
                Spacer(minLength: 0)
                if let trailing = trailing { trailing }
            }
            content()
        }
    }
}
