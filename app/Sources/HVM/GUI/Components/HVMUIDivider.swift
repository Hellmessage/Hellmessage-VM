// HVMUIDivider.swift — 新 GUI 分隔线. 1px hairline + borderDefault, 水平/垂直两向 + 可选 padding.
// 用法: HVMUI.Divider() / HVMUI.Divider(.vertical, padding: .md)


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

