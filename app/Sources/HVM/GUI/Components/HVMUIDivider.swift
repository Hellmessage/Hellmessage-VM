// HVMUIDivider.swift — 新 GUI 分隔线 (PR-C5)
//
// 用法:
//   HVMUI.Divider()                        // 水平 1px hairline + sm vertical padding
//   HVMUI.Divider(padding: .lg)            // 大间距
//   HVMUI.Divider(padding: .none)          // 无 padding (紧贴上下内容)
//   HVMUI.Divider(.vertical)               // 垂直 1px (HStack 内分隔)
//   HVMUI.Divider(.vertical, padding: .md) // 垂直带横向 padding
//
// 视觉:
//   - 1px hairline + borderDefault (white α 0.08)
//   - 水平时 frame(maxWidth: .infinity, height: 1)
//   - 垂直时 frame(width: 1, height 跟随 parent HStack 高度)

#if NEW_GUI

import SwiftUI

extension HVMUI {

struct Divider: View {
    enum Orientation {
        case horizontal, vertical
    }

    enum Padding {
        case none, sm, md, lg

        var value: CGFloat {
            switch self {
            case .none: return 0
            case .sm:   return HVMTheme.space.sm
            case .md:   return HVMTheme.space.md
            case .lg:   return HVMTheme.space.lg
            }
        }
    }

    private let orientation: Orientation
    private let padding: Padding

    init(_ orientation: Orientation = .horizontal, padding: Padding = .sm) {
        self.orientation = orientation
        self.padding = padding
    }

    var body: some View {
        switch orientation {
        case .horizontal:
            Rectangle()
                .fill(HVMTheme.color.borderDefault)
                .frame(maxWidth: .infinity)
                .frame(height: HVMTheme.border.hairline)
                .padding(.vertical, padding.value)

        case .vertical:
            Rectangle()
                .fill(HVMTheme.color.borderDefault)
                .frame(width: HVMTheme.border.hairline)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, padding.value)
        }
    }
}

}  // extension HVMUI 结束

#endif
