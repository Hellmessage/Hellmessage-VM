// HVMUICheckbox.swift — 新 GUI 方框勾选.
//
// 3 态: off (空框) / on (青底 checkmark) / indeterminate (青底 minus 半选, 给"全选" parent).
//   indeterminate 优先: 同时设 isOn / indeterminate 时显示 minus.
// 3 size: .sm 14 / .md 16 (default) / .lg 20.
// 用法: HVMUI.Checkbox("我同意条款", isOn: $accepted, probeID: "...")


import SwiftUI
import HVMGuiProbe

extension HVMUI {

struct Checkbox: View {
    private let label: String?
    @Binding private var isOn: Bool
    private let indeterminate: Bool
    private let size: CheckboxSize
    private let isDisabled: Bool
    private let probeID: String

    init(_ label: String? = nil,
         isOn: Binding<Bool>,
         indeterminate: Bool = false,
         size: CheckboxSize = .md,
         disabled: Bool = false,
         probeID: String) {
        self.label = label
        self._isOn = isOn
        self.indeterminate = indeterminate
        self.size = size
        self.isDisabled = disabled
        self.probeID = probeID
    }

    enum CheckboxSize {
        case sm, md, lg

        var box: CGFloat {
            switch self {
            case .sm: return 14
            case .md: return 16
            case .lg: return 20
            }
        }

        var iconFont: Font {
            switch self {
            case .sm: return Font.system(size: 9, weight: .bold)
            case .md: return Font.system(size: 11, weight: .bold)
            case .lg: return Font.system(size: 14, weight: .bold)
            }
        }

        var labelFont: Font {
            switch self {
            case .sm: return HVMTheme.font.sm
            case .md: return HVMTheme.font.base
            case .lg: return HVMTheme.font.md
            }
        }
    }

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    /// 视觉是否"已勾" (含半选)
    private var isMarked: Bool { isOn || indeterminate }

    var body: some View {
        SwiftUI.Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: HVMTheme.space.sm) {
                box
                if let label {
                    Text(label)
                        .font(size.labelFont)
                        .foregroundStyle(isDisabled ? HVMTheme.color.textTertiary
                                                    : HVMTheme.color.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(isDisabled)
        .onHover { if !isDisabled { isHovered = $0 } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(
            indeterminate ? "部分选中" : (isOn ? "已选中" : "未选中")
        )
        .modifier(ProbeCheckboxModifier(
            probeID: probeID,
            label: label ?? "",
            isOn: $isOn,
            isDisabled: isDisabled
        ))
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                .fill(boxFill)
                .frame(width: size.box, height: size.box)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                        .stroke(boxBorder, lineWidth: HVMTheme.border.hairline)
                )
                .overlay(focusRing)

            // icon (checkmark / minus)
            if isMarked {
                Image(systemName: indeterminate ? "minus" : "checkmark")
                    .font(size.iconFont)
                    .foregroundStyle(iconColor)
                    .scaleEffect(isMarked ? 1.0 : 0.6)
                    .opacity(isMarked ? 1 : 0)
            }
        }
        .animation(HVMTheme.motion.pressSpring, value: isMarked)
        .animation(HVMTheme.motion.easeOutFast, value: isHovered)
        .animation(HVMTheme.motion.easeOut, value: isFocused)
    }

    /// disabled+marked 走 bgDisabled (灰底 + 灰勾, 不用 accent 误导能点); off 态透明底.
    private var boxFill: Color {
        if isDisabled {
            return isMarked ? HVMTheme.color.bgDisabled : HVMTheme.color.transparent
        }
        if isMarked {
            return isHovered ? HVMTheme.color.accentHover : HVMTheme.color.accent
        }
        return isHovered ? HVMTheme.color.bgHover : HVMTheme.color.transparent
    }

    private var boxBorder: Color {
        // disabled 始终保留 border (否则 bgDisabled 上靠 textTertiary 勾撑形太弱)
        if isDisabled { return HVMTheme.color.borderDefault }
        if isMarked { return HVMTheme.color.transparent }
        // off 态用 borderEmphasis 让 sectionCard (bgRaised) 内方框轮廓清晰
        return HVMTheme.color.borderEmphasis
    }

    private var iconColor: Color {
        isDisabled ? HVMTheme.color.textTertiary : HVMTheme.color.textOnAccent
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                .stroke(HVMTheme.color.borderFocus, lineWidth: HVMTheme.border.focus)
        }
    }
}

}  // extension HVMUI 结束

private struct ProbeCheckboxModifier: ViewModifier {
    let probeID: String
    let label: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if !isDisabled {
            content.hvmProbe(
                id: probeID,
                label: label,
                action: .toggle(
                    getter: { isOn },
                    setter: { isOn = $0 }
                )
            )
        } else {
            content
        }
    }
}

