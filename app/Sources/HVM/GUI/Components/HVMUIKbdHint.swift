// HVMUIKbdHint.swift — 新 GUI 键盘快捷键 chip (圆角矩形 + hairline + bgOverlay + mono 字).
// 2 size: .sm 16 高 / .md 20 高 (default).
// 用法: HVMUI.KbdHint("⌘+S") / HVMUI.KbdHint(keys: [.cmd, .shift], char: "S")


import SwiftUI

extension HVMUI {

struct KbdHint: View {
    enum HintSize {
        case sm, md

        var height: CGFloat {
            switch self {
            case .sm: return 16
            case .md: return 20
            }
        }

        var font: Font {
            switch self {
            case .sm: return HVMTheme.font.monoSm
            case .md: return HVMTheme.font.mono
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .sm: return HVMTheme.space.xs
            case .md: return HVMTheme.space.sm
            }
        }
    }

    /// 修饰键 / 主键枚举 — 让业务侧 typed 拼装, 不写 magic string.
    enum Key: String {
        case cmd   = "⌘"
        case shift = "⇧"
        case opt   = "⌥"
        case ctrl  = "⌃"
        case enter = "⏎"
        case esc   = "⎋"
        case tab   = "⇥"
        case space = "␣"
        case delete = "⌫"
        case up    = "↑"
        case down  = "↓"
        case left  = "←"
        case right = "→"
        // 字母 / 数字 用 character(...) 自定义
    }

    private let display: String
    private let size: HintSize

    init(_ display: String, size: HintSize = .md) {
        self.display = display
        self.size = size
    }

    /// 从 Key 数组拼接, 自动 + 分隔; 末尾可加字符 (例 [.cmd, .shift] + "S" → "⌘+⇧+S")
    init(keys: [Key], char: String? = nil, size: HintSize = .md) {
        let parts = keys.map(\.rawValue) + (char.map { [$0] } ?? [])
        self.display = parts.joined(separator: "+")
        self.size = size
    }

    var body: some View {
        Text(display)
            .font(size.font)
            .foregroundStyle(HVMTheme.color.textSecondary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(
                RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                    .fill(HVMTheme.color.bgOverlay)
                    .overlay(
                        RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                            .stroke(HVMTheme.color.borderDefault,
                                    lineWidth: HVMTheme.border.hairline)
                    )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("快捷键 \(display)")
    }
}

}  // extension HVMUI 结束

