// HVMUIToggle.swift — 新 GUI 滑块开关.
//
// 3 size: .sm 28×16 / .md 36×20 (default) / .lg 44×24. 可带 label / hint.
// 视觉: off bgOverlay 圆点左 / on accent 圆点右, 切换 spring, focus ring.
// 用法: HVMUI.Toggle("自动启动 VM", isOn: $autoStart, probeID: "...")
//
// probe: 挂 .toggle(getter, setter), hvm-dbg gui click 走 setter 取反; gui read 取 getter.


import SwiftUI
import HVMGuiProbe

extension HVMUI {

struct Toggle: View {
    private let label: String?
    private let hint: String?
    @Binding private var isOn: Bool
    private let size: ToggleSize
    private let isDisabled: Bool
    private let probeID: String

    init(_ label: String? = nil,
         isOn: Binding<Bool>,
         hint: String? = nil,
         size: ToggleSize = .md,
         disabled: Bool = false,
         probeID: String) {
        self.label = label
        self._isOn = isOn
        self.hint = hint
        self.size = size
        self.isDisabled = disabled
        self.probeID = probeID
    }

    enum ToggleSize {
        case sm, md, lg

        var width: CGFloat {
            switch self {
            case .sm: return 28
            case .md: return 36
            case .lg: return 44
            }
        }

        var height: CGFloat {
            switch self {
            case .sm: return 16
            case .md: return 20
            case .lg: return 24
            }
        }

        var dotDiameter: CGFloat { height - 4 }

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

    var body: some View {
        SwiftUI.Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: HVMTheme.space.sm) {
                slider
                if label != nil || hint != nil {
                    labelStack
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .disabled(isDisabled)
        .onHover { if !isDisabled { isHovered = $0 } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? hint ?? "")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isToggle)
        .modifier(ProbeToggleModifier(
            probeID: probeID,
            label: label ?? hint ?? "",
            isOn: $isOn,
            isDisabled: isDisabled
        ))
    }

    @ViewBuilder
    private var labelStack: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
            if let label {
                Text(label)
                    .font(size.labelFont)
                    .foregroundStyle(isDisabled ? HVMTheme.color.textTertiary
                                                : HVMTheme.color.textPrimary)
            }
            if let hint {
                Text(hint)
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
        }
    }

    /// 容器 bg. off 用 bgOverlay (比 bgRaised 亮一档) 让 sectionCard 内嵌入时轮廓清晰.
    private var sliderBg: Color {
        if isDisabled { return HVMTheme.color.bgDisabled }
        return isOn ? HVMTheme.color.accent : HVMTheme.color.bgOverlay
    }

    private var dotColor: Color {
        isDisabled ? HVMTheme.color.textTertiary : HVMTheme.color.textPrimary
    }

    private var borderColor: Color {
        if isDisabled { return HVMTheme.color.borderDefault }
        if isOn { return HVMTheme.color.transparent }
        return HVMTheme.color.borderEmphasis
    }

    private var slider: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: size.height / 2)
                .fill(sliderBg)
                .frame(width: size.width, height: size.height)
                .overlay(
                    // hover layer (off 态时更明显)
                    RoundedRectangle(cornerRadius: size.height / 2)
                        .fill(HVMTheme.color.bgHover)
                        .opacity(isHovered && !isOn ? 1 : 0)
                )
                .overlay(
                    // 边框: off 用 borderEmphasis 让 sectionCard 内轮廓清晰; on accent 够亮跳过; disabled 弱 borderDefault
                    RoundedRectangle(cornerRadius: size.height / 2)
                        .stroke(borderColor, lineWidth: HVMTheme.border.hairline)
                )
                .overlay(focusRing)

            // 圆点 (white 或 disabled 灰)
            Circle()
                .fill(dotColor)
                .frame(width: size.dotDiameter, height: size.dotDiameter)
                .padding(.horizontal, 2)
        }
        .animation(HVMTheme.motion.pressSpring, value: isOn)
        .animation(HVMTheme.motion.easeOutFast, value: isHovered)
        .animation(HVMTheme.motion.easeOut, value: isFocused)
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: size.height / 2)
                .stroke(HVMTheme.color.borderFocus, lineWidth: HVMTheme.border.focus)
        }
    }
}

}  // extension HVMUI 结束

/// Probe 集成 modifier — Toggle 用 .toggle(getter, setter), gui click 取反 / gui read 取值.
private struct ProbeToggleModifier: ViewModifier {
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

