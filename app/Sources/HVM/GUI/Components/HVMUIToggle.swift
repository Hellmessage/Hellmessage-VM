// HVMUIToggle.swift — 新 GUI 滑块开关 (PR-C3)
//
// 用法:
//   HVMUI.Toggle("自动启动 VM", isOn: $autoStart)
//   HVMUI.Toggle("启用网络", isOn: $networkOn, hint: "需 vmnet daemon 在跑",
//                probeID: "settings.toggle.network")
//   HVMUI.Toggle(isOn: $isCompact, size: .sm)   // 仅滑块 inline
//
// size:
//   .sm — 28×16 (toolbar 内联), .md — 36×20 (default), .lg — 44×24 (设置页)
//
// 视觉:
//   - off: bg = bgRaised, 圆点 left
//   - on : bg = accent (青), 圆点 right
//   - 切换: 圆点位置 + bg 色 spring (HVMTheme.motion.pressSpring)
//   - focus: 容器外 2px borderFocus ring (键盘 Tab 才显; 鼠标 click 不出)
//   - hover: layer alpha 0 → 0.04
//   - disabled: opacity 0.4 + 跳过 hover / focus / probe
//
// 键盘 + a11y:
//   - SwiftUI.Button wrap → 自带 Space / Return 触发
//   - accessibilityLabel = label
//   - accessibilityValue = "已开启" / "已关闭"
//   - accessibilityAddTraits(.isToggle)
//
// probe: probeID 非 nil 时挂 .hvmProbe(action: .toggle(getter, setter)).
// hvm-dbg gui click --identifier X 走 setter 取反; gui read 取 getter.

#if NEW_GUI

import SwiftUI
import HVMGuiProbe

extension HVMUI {

struct Toggle: View {
    private let label: String?
    private let hint: String?
    @Binding private var isOn: Bool
    private let size: ToggleSize
    private let isDisabled: Bool
    private let probeID: String?

    init(_ label: String? = nil,
         isOn: Binding<Bool>,
         hint: String? = nil,
         size: ToggleSize = .md,
         disabled: Bool = false,
         probeID: String? = nil) {
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

    /// 容器 bg.
    /// off 用 bgOverlay (#18191B) 而不是 bgRaised — sectionCard 已经是 bgRaised,
    /// 跟 sectionCard 同色容器会跟卡片 bg 融合, 仅靠白圆点能看出形, 整体轮廓不清晰.
    /// bgOverlay 比 bgRaised 亮一档, 在 sectionCard 内嵌入时轮廓明显.
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
            // 容器
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
                    // 边框: off 用 borderEmphasis (强一档, 让 off 容器在 sectionCard
                    // 内有清晰轮廓); on 态 accent 已经够亮跳过描边; disabled 保留弱
                    // borderDefault 让"灰化"感成立
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

/// Probe 集成 modifier — Toggle 用 .toggle(getter, setter).
/// hvm-dbg gui click --identifier X 走 setter(!isOn); gui read --identifier X
/// 走 getter 返 "true"/"false".
private struct ProbeToggleModifier: ViewModifier {
    let probeID: String?
    let label: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if let probeID, !isDisabled {
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

#endif
