// HVMUISelect.swift — 新 GUI 下拉选择 (PR-C4)
//
// 自家绘制 (不用 NSPopUpButton / NSMenu), trigger 复用 HVMUI.FieldChrome.
// 下拉用 SwiftUI .popover 容器但内容完全自绘, 选项列表 / 搜索 / 键盘导航全自家管.
//
// 用法:
//   HVMUI.Select("引擎", selection: $engine, options: [
//       .init(value: .vz,   label: "VZ (推荐)", hint: "Apple 原生"),
//       .init(value: .qemu, label: "QEMU",     hint: "Windows ARM64"),
//   ])
//
//   HVMUI.Select("ISO", selection: $iso, options: isoList,
//                placeholder: "选择 ISO 镜像...",
//                searchable: true,
//                probeID: "dialog.createVM.select.iso")
//
// 视觉:
//   - trigger: FieldChrome 外框 (跟 TextField 同) + label 主 / chevron.down 右
//   - popover: bgOverlay 卡片, 1px borderDefault, 阴影一档, 圆角 lg
//   - row 高 32, hover bgHover, 当前 selection 行尾 checkmark accent
//   - keyboard 高亮: accentMuted bg + 1px borderFocus 边
//
// 键盘:
//   - trigger focus + Space/Return/Down 开下拉
//   - 下拉内 ↑↓ 切 highlight, Enter 选定, Esc 关
//   - searchable 时 search field 抢首焦, 文字过滤选项
//
// a11y:
//   - trigger accessibilityLabel = label
//   - accessibilityValue = 当前 option.label (或 placeholder 当 nil)
//   - 选项 row accessibilityElement 朗读 "选中" / "未选中"
//
// probe: 用 .textField role (ProbeAction 没 generic .select):
//   - getter 返当前 option.label
//   - setter 接 label 字符串, 内部 first(where: $0.label == X) 选中
//   - hvm-dbg gui type --identifier X --text "VZ (推荐)" 选 VZ 选项

#if NEW_GUI

import SwiftUI
import HVMGuiProbe

extension HVMUI {

/// Select 选项 — generic value 类型 (常用 enum / String / Int).
struct SelectOption<Value: Hashable>: Identifiable {
    let id = UUID()
    let value: Value
    let label: String
    let hint: String?
    let icon: String?

    init(value: Value, label: String, hint: String? = nil, icon: String? = nil) {
        self.value = value
        self.label = label
        self.hint = hint
        self.icon = icon
    }
}

struct Select<Value: Hashable>: View {
    private let label: String?
    private let placeholder: String
    @Binding private var selection: Value?
    private let options: [SelectOption<Value>]
    private let size: FieldSize
    private let icon: String?
    private let searchable: Bool
    private let errorMessage: String?
    private let isLoading: Bool
    private let isDisabled: Bool
    private let probeID: String?

    init(_ label: String? = nil,
         selection: Binding<Value?>,
         options: [SelectOption<Value>],
         placeholder: String = "请选择...",
         size: FieldSize = .md,
         icon: String? = nil,
         searchable: Bool = false,
         errorMessage: String? = nil,
         isLoading: Bool = false,
         disabled: Bool = false,
         probeID: String? = nil) {
        self.label = label
        self._selection = selection
        self.options = options
        self.placeholder = placeholder
        self.size = size
        self.icon = icon
        self.searchable = searchable
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.isDisabled = disabled
        self.probeID = probeID
    }

    /// 非可选 selection 便利 init (有默认值场景)
    init(_ label: String? = nil,
         selection: Binding<Value>,
         options: [SelectOption<Value>],
         placeholder: String = "请选择...",
         size: FieldSize = .md,
         icon: String? = nil,
         searchable: Bool = false,
         errorMessage: String? = nil,
         isLoading: Bool = false,
         disabled: Bool = false,
         probeID: String? = nil) {
        self.label = label
        self._selection = Binding(
            get: { selection.wrappedValue },
            set: { if let v = $0 { selection.wrappedValue = v } }
        )
        self.options = options
        self.placeholder = placeholder
        self.size = size
        self.icon = icon
        self.searchable = searchable
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.isDisabled = disabled
        self.probeID = probeID
    }

    @State private var isOpen = false
    @State private var isHovered = false
    @State private var searchText = ""
    @State private var highlightedIndex: Int = 0
    @FocusState private var triggerFocused: Bool

    private var currentOption: SelectOption<Value>? {
        guard let selection else { return nil }
        return options.first(where: { $0.value == selection })
    }

    private var filteredOptions: [SelectOption<Value>] {
        guard searchable, !searchText.isEmpty else { return options }
        return options.filter { $0.label.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
            if let label {
                SwiftUI.Text(label)
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
            }

            trigger
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label ?? placeholder)
                .accessibilityValue(currentOption?.label ?? placeholder)
                .modifier(ProbeSelectModifier(
                    probeID: probeID,
                    label: label ?? placeholder,
                    selection: $selection,
                    options: options,
                    isDisabled: isDisabled
                ))

            if let errorMessage {
                SwiftUI.Text(errorMessage)
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
                    .transition(.opacity)
            }
        }
        .animation(HVMTheme.motion.easeOut, value: errorMessage != nil)
    }

    private var trigger: some View {
        SwiftUI.Button {
            if !isDisabled && !isLoading {
                openPopover()
            }
        } label: {
            HStack(spacing: HVMTheme.space.sm) {
                if let icon = icon ?? currentOption?.icon {
                    Image(systemName: icon)
                        .font(size.font)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                }

                SwiftUI.Text(currentOption?.label ?? placeholder)
                    .font(size.font)
                    .foregroundStyle(currentOption == nil
                                     ? HVMTheme.color.textTertiary
                                     : HVMTheme.color.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(size.spinnerScale)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(size.font)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($triggerFocused)
        .disabled(isDisabled)
        .modifier(FieldChrome(
            size: size,
            isFocused: triggerFocused || isOpen,
            isHovered: isHovered && !isDisabled,
            isError: errorMessage != nil,
            isDisabled: isDisabled
        ))
        .onHover { isHovered = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PopoverContent(
                options: filteredOptions,
                searchable: searchable,
                searchText: $searchText,
                highlightedIndex: $highlightedIndex,
                currentValue: selection,
                onSelect: selectOption,
                onClose: { isOpen = false }
            )
            .frame(minWidth: 240, maxWidth: 360)
        }
    }

    private func openPopover() {
        searchText = ""
        highlightedIndex = options.firstIndex(where: { $0.value == selection }) ?? 0
        isOpen = true
    }

    private func selectOption(_ option: SelectOption<Value>) {
        selection = option.value
        isOpen = false
    }

    private func selectByLabel(_ label: String) {
        if let opt = options.first(where: { $0.label == label }) {
            selection = opt.value
        }
    }
}

/// 下拉内容 — search + 选项列表 + 键盘导航
private struct PopoverContent<Value: Hashable>: View {
    let options: [HVMUI.SelectOption<Value>]
    let searchable: Bool
    @Binding var searchText: String
    @Binding var highlightedIndex: Int
    let currentValue: Value?
    let onSelect: (HVMUI.SelectOption<Value>) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searchable {
                HVMUI.TextField(
                    text: $searchText,
                    placeholder: "搜索...",
                    size: .sm,
                    icon: "magnifyingglass"
                )
                .padding(HVMTheme.space.sm)
                .focused($searchFocused)
            }

            if options.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { idx, opt in
                            row(idx: idx, option: opt)
                        }
                    }
                    .padding(.vertical, HVMTheme.space.xs)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(HVMTheme.color.bgOverlay)
        .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                .stroke(HVMTheme.color.borderDefault, lineWidth: HVMTheme.border.hairline)
        )
        .onAppear {
            if searchable { searchFocused = true }
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !options.isEmpty {
                highlightedIndex = max(0, highlightedIndex - 1)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !options.isEmpty {
                highlightedIndex = min(options.count - 1, highlightedIndex + 1)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if options.indices.contains(highlightedIndex) {
                onSelect(options[highlightedIndex])
            }
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: HVMTheme.space.xs) {
            Image(systemName: "magnifyingglass")
                .font(HVMTheme.font.lg)
                .foregroundStyle(HVMTheme.color.textTertiary)
            SwiftUI.Text("无匹配项")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HVMTheme.space.xl)
    }

    private func row(idx: Int, option: HVMUI.SelectOption<Value>) -> some View {
        let isSelected = option.value == currentValue
        let isHighlighted = idx == highlightedIndex

        return SwiftUI.Button {
            onSelect(option)
        } label: {
            HStack(spacing: HVMTheme.space.sm) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(HVMTheme.font.md)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 0) {
                    SwiftUI.Text(option.label)
                        .font(HVMTheme.font.md)
                        .foregroundStyle(HVMTheme.color.textPrimary)
                    if let hint = option.hint {
                        SwiftUI.Text(hint)
                            .font(HVMTheme.font.xs)
                            .foregroundStyle(HVMTheme.color.textSecondary)
                    }
                }
                Spacer(minLength: HVMTheme.space.md)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(HVMTheme.font.md)
                        .foregroundStyle(HVMTheme.color.accent)
                }
            }
            .padding(.horizontal, HVMTheme.space.md)
            .padding(.vertical, HVMTheme.space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBg(isHighlighted: isHighlighted))
            .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.sm))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, HVMTheme.space.xs)
        .onHover { hovered in
            if hovered { highlightedIndex = idx }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
    }

    private func rowBg(isHighlighted: Bool) -> Color {
        isHighlighted ? HVMTheme.color.accentMuted : HVMTheme.color.transparent
    }
}

}  // extension HVMUI 结束

/// Probe 集成 — 用 .textField role (ProbeAction 没 generic .select).
/// 必须 @Binding selection + options 数组才能在 getter / setter closure 里动态算
/// 最新值; 如果传 snapshot 字符串, ProbeRegistry.register 之后值不再更新.
private struct ProbeSelectModifier<Value: Hashable>: ViewModifier {
    let probeID: String?
    let label: String
    @Binding var selection: Value?
    let options: [HVMUI.SelectOption<Value>]
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if let probeID, !isDisabled {
            content.hvmProbe(
                id: probeID,
                label: label,
                action: .textField(
                    getter: {
                        options.first(where: { $0.value == selection })?.label ?? ""
                    },
                    setter: { lbl in
                        if let opt = options.first(where: { $0.label == lbl }) {
                            selection = opt.value
                        }
                    }
                )
            )
        } else {
            content
        }
    }
}

#endif
