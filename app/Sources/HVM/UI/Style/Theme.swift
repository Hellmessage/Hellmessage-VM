// Theme.swift
// Terminal / Hacker 风格统一 token.
// 纯黑三层底 + 青绿单色 accent + SF Mono 主导 + 1px 细边

import SwiftUI

public enum HVMColor {
    // 背景: 纯黑三层 (从外到内)
    public static let bgBase       = Color(red: 0.000, green: 0.000, blue: 0.000)     // #000
    public static let bgSidebar    = Color(red: 0.027, green: 0.027, blue: 0.031)     // #070708
    public static let bgCard       = Color(red: 0.043, green: 0.047, blue: 0.055)     // #0B0C0E
    public static let bgCardHi     = Color(red: 0.063, green: 0.067, blue: 0.078)
    public static let bgElevated   = Color(red: 0.082, green: 0.086, blue: 0.098)
    public static let bgHover      = Color.white.opacity(0.04)
    public static let bgSelected   = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.10)

    public static let border       = Color.white.opacity(0.08)
    public static let borderStrong = Color.white.opacity(0.16)
    public static let borderAccent = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.55)

    public static let textPrimary   = Color(red: 0.92, green: 0.93, blue: 0.94)
    public static let textSecondary = Color(red: 0.54, green: 0.56, blue: 0.60)
    public static let textTertiary  = Color(red: 0.32, green: 0.34, blue: 0.38)
    public static let textOnAccent  = Color.black

    // 单色 accent: 青绿 #00E5CC, hacker / terminal 感
    public static let accent       = Color(red: 0.000, green: 0.898, blue: 0.800)
    public static let accentHover  = Color(red: 0.180, green: 0.960, blue: 0.870)
    public static let accentMuted  = Color(red: 0.000, green: 0.898, blue: 0.800).opacity(0.15)

    public static let statusRunning = Color(red: 0.22, green: 0.94, blue: 0.56)     // #39F08E
    public static let statusStopped = Color(red: 0.40, green: 0.43, blue: 0.47)
    public static let statusPaused  = Color(red: 1.00, green: 0.78, blue: 0.20)
    public static let statusError   = Color(red: 1.00, green: 0.33, blue: 0.33)

    public static let danger       = Color(red: 1.00, green: 0.33, blue: 0.33)

    // 系列 accent (用于 stat icon tint, 全部冷色避免破坏 hacker 风)
    public static let statCPU     = Color(red: 0.00, green: 0.90, blue: 0.80)      // 青绿
    public static let statMemory  = Color(red: 0.70, green: 0.80, blue: 1.00)      // 冷蓝
    public static let statDisk    = Color(red: 1.00, green: 0.78, blue: 0.20)      // 琥珀
    public static let statNetwork = Color(red: 0.35, green: 0.90, blue: 0.55)      // 绿
}

public enum HVMSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum HVMRadius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 10
    public static let pill: CGFloat = 999
}

public enum HVMBar {
    public static let toolbarHeight: CGFloat  = 42
    public static let statusBarHeight: CGFloat = 26
}

/// 主窗口尺寸. 用户日常想调主窗口大小直接改这里.
public enum HVMWindow {
    /// 创建窗口时的 contentRect 尺寸 (打开时的默认大小)
    public static let mainDefault   = CGSize(width: 1200, height: 1090)
    /// 窗口最小尺寸 (用户拖拽缩放下限)
    public static let mainMin       = CGSize(width: 1020, height: 640)
    /// VM 退出后切回 stopped 视图时把窗口拉回的"舒适"尺寸 (避免 running 时撑大的窗口尺寸继续占屏)
    public static let mainStopped   = CGSize(width: 1080, height: 720)
}

public enum HVMFont {
    // proportional (标题 / 名字 / 大数字)
    public static let hero    = Font.system(size: 22, weight: .semibold)
    public static let title   = Font.system(size: 16, weight: .semibold)
    public static let heading = Font.system(size: 13, weight: .semibold)

    // mono (正文 / 详情 / 状态 / label)
    public static let body       = Font.system(size: 12, design: .monospaced)
    public static let bodyBold   = Font.system(size: 12, weight: .semibold, design: .monospaced)
    public static let caption    = Font.system(size: 11, design: .monospaced)
    public static let small      = Font.system(size: 10, design: .monospaced)
    public static let label      = Font.system(size: 10, weight: .bold, design: .monospaced)
    public static let statValue  = Font.system(size: 22, weight: .semibold, design: .monospaced)
}

/// 大写 + tracking 的标签文字, 用于 section header
public struct LabelText: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = HVMColor.textTertiary) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text.uppercased())
            .font(HVMFont.label)
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// 网络模式等横向分段: 选中用 `bgSelected` + 青绿描边与字色, 避免整块高亮 contrast 过硬
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
                    .fill(selected ? HVMColor.bgSelected : HVMColor.bgBase)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .stroke(selected ? HVMColor.borderAccent : HVMColor.border, lineWidth: 1)
            )
            .opacity(disabled ? 0.45 : 1.0)
    }
}

/// 与 `TextField(roundedBorder)` 同宽的 menu 形 Picker 外框, 右缘与整表对齐
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
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .fill(HVMColor.bgCardHi)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                    .stroke(HVMColor.border, lineWidth: 1)
            )
    }
}

/// 自绘下拉: 与 `HVMFormMenuField` 同字色/边距, 在槽位下方**内联**展开列表 (无 popover 气球/尖角), 与 `HVMNetModeSegment` 的选中/描边语汇一致
public struct HVMFormSelect: View {
    public let options: [(value: String, label: String)]
    @Binding public var selection: String
    /// 无障碍读名
    public var accessibilityLabel: String

    @State private var isOpen: Bool = false
    @State private var hoveredValue: String?

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
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: HVMSpace.sm) {
                    Text(currentLabel)
                        .font(HVMFont.body)
                        .foregroundStyle(HVMColor.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(HVMColor.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HVMSpace.md)
            .padding(.vertical, 5)
            .background(HVMColor.bgCardHi)

            if isOpen {
                Rectangle()
                    .fill(HVMColor.border)
                    .frame(height: 1)
                listBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous)
                .stroke(isOpen ? HVMColor.borderAccent : HVMColor.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HVMRadius.sm, style: .continuous))
        .animation(.snappy(duration: 0.18), value: isOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(currentLabel)
        .focusable()
        .onKeyPress(.escape) {
            guard isOpen else { return .ignored }
            isOpen = false
            return .handled
        }
        .onChange(of: isOpen) { _, new in
            if !new { hoveredValue = nil }
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let selectBlock: (String) -> Void = { v in
            selection = v
            isOpen = false
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options, id: \.value) { opt in
                    let isSel = (selection == opt.value)
                    Button {
                        selectBlock(opt.value)
                    } label: {
                        HStack(spacing: HVMSpace.sm) {
                            Text(opt.label)
                                .font(HVMFont.body)
                                .foregroundStyle(isSel ? HVMColor.accent : HVMColor.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if isSel {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(HVMColor.accent)
                            }
                        }
                        .padding(.horizontal, HVMSpace.md)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(rowFill(isSelected: isSel, value: opt.value))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside {
                            hoveredValue = opt.value
                        } else if hoveredValue == opt.value {
                            hoveredValue = nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
        .background(HVMColor.bgBase)
    }

    private func rowFill(isSelected: Bool, value: String) -> Color {
        if isSelected { return HVMColor.bgSelected }
        if hoveredValue == value { return HVMColor.bgHover }
        return .clear
    }
}

/// 脉冲 running 点
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
                .fill(color.opacity(0.35))
                .frame(width: size * 2.6, height: size * 2.6)
                .scaleEffect(animating ? 1.2 : 0.8)
                .opacity(animating ? 0 : 1)
                .animation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false),
                    value: animating
                )
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.6), radius: size * 0.8)
        }
        .frame(width: size * 3, height: size * 3)
        .onAppear { animating = true }
    }
}

/// terminal 风 section container: 顶部 `┌─ TITLE ──` 边角, 内容包在细边框里
public struct TerminalSection<Content: View>: View {
    let title: String
    let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            HStack(spacing: 6) {
                Text("┌─")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.border)
                Text(title.uppercased())
                    .font(HVMFont.label)
                    .tracking(1.6)
                    .foregroundStyle(HVMColor.textSecondary)
                Text(String(repeating: "─", count: 64))
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.border)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            content()
                .padding(.leading, HVMSpace.sm)
        }
    }
}
