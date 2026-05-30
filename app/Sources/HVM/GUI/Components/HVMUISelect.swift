// HVMUISelect.swift — 新 GUI 下拉选择.
//
// 自家绘制 (不用 NSPopUpButton / NSMenu / SwiftUI .popover), trigger 复用 FieldChrome,
// 下拉用 .overlay 浮窗 (bgOverlay + 边框 + 圆角 + 自家 shadow). 支持 searchable + 键盘导航.
// 用法: HVMUI.Select("引擎", selection: $engine, options: [...], probeID: "...")
//
// probe 用 .textField role (无 generic .select): getter 返当前 option.label, setter 按 label 匹配选中.
//   hvm-dbg gui type --identifier X --text "<label>" 选对应项.


import SwiftUI
import AppKit
import HVMGuiProbe

extension HVMUI {

/// 全局 select 协调器 — 保证一次最多一个下拉框打开. 每个 Select 持 UUID,
/// openPopover() 时设 openSelectID = self.id, 其他 Select 监听 .onChange 发现不是自己就关.
@MainActor
@Observable
final class SelectCoordinator {
    static let shared = SelectCoordinator()
    var openSelectID: UUID? = nil
    private init() {}
}

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
    private let probeID: String

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
         probeID: String) {
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
         probeID: String) {
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
    /// 每个 Select 唯一 ID, 给 SelectCoordinator 识别"当前打开的 select".
    @State private var instanceID = UUID()
    private let coordinator = SelectCoordinator.shared

    /// 触发器底边在窗口内的 Y (.global 坐标), 用来按"触发器下方可用空间"动态限下拉高度防被裁.
    @State private var triggerMaxYGlobal: CGFloat = 0
    private var dropdownMaxHeight: CGFloat {
        let winH = NSApp.keyWindow?.contentView?.bounds.height ?? 0
        guard winH > 0, triggerMaxYGlobal > 0 else { return 280 }
        let below = winH - triggerMaxYGlobal - HVMTheme.space.lg   // 触发器下方到窗口底的余量
        return max(120, min(280, below))                            // 至少 120 (太矮没意义), 至多 280
    }

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
                // trigger zIndex 高于 errorMessage, 让 overlay popover 浮在红字之上
                .zIndex(10)

            if let errorMessage {
                SwiftUI.Text(errorMessage)
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(HVMTheme.motion.easeOut, value: errorMessage != nil)
        // 监听协调器 — 其他 Select 打开时把自己关掉, 保证一次最多一个 popover
        .onChange(of: coordinator.openSelectID) { _, newID in
            if newID != instanceID && isOpen {
                isOpen = false
            }
        }
    }

    /// 切换 popover 打开 / 关闭. trigger button + trigger probe (<probeID>.trigger) 都调它.
    private func toggleOpen() {
        if isDisabled || isLoading { return }
        if isOpen { isOpen = false } else { openPopover() }
    }

    private var trigger: some View {
        SwiftUI.Button {
            toggleOpen()
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
            // 内化 padding + frame + contentShape, 让 button hit test 覆盖整个 padding 区
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: size.height)
            .contentShape(Rectangle())
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
        .modifier(ProbeSelectTriggerModifier(
            probeID: "\(probeID).trigger",
            label: (label ?? placeholder) + " (打开/关闭下拉)",
            toggle: { toggleOpen() },
            isDisabled: isDisabled
        ))
        // popover 用 .overlay(alignment:) 脱离 layout flow 浮在 trigger 下方, 配合 zIndex 压在下方控件之上.
        // 测触发器底边在窗口的 Y, 给 dropdownMaxHeight 算可用空间.
        .background(
            GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global).maxY, initial: true) { _, ny in
                    triggerMaxYGlobal = ny
                }
            }
        )
        .overlay(alignment: .topLeading) {
            if isOpen {
                PopoverContent(
                    selectProbeID: probeID,
                    options: filteredOptions,
                    searchable: searchable,
                    searchText: $searchText,
                    highlightedIndex: $highlightedIndex,
                    currentValue: selection,
                    onSelect: selectOption,
                    onClose: { isOpen = false },
                    maxHeight: dropdownMaxHeight
                )
                // popover 宽度 = trigger 宽度 (frame maxWidth + fixedSize horizontal:false);
                // fixedSize vertical:true 让高度用 content ideal size.
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: size.height + HVMTheme.space.xs)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(HVMTheme.motion.easeOut, value: isOpen)
    }

    private func openPopover() {
        searchText = ""
        highlightedIndex = options.firstIndex(where: { $0.value == selection }) ?? 0
        isOpen = true
        // 告诉协调器 "我打开了" — 其他 Select 监听到会关掉自己
        coordinator.openSelectID = instanceID
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
    let selectProbeID: String   // 外层 Select probeID, 给 search field 拼派生 id
    let options: [HVMUI.SelectOption<Value>]
    let searchable: Bool
    @Binding var searchText: String
    @Binding var highlightedIndex: Int
    let currentValue: Value?
    let onSelect: (HVMUI.SelectOption<Value>) -> Void
    let onClose: () -> Void
    /// 下拉列表最大高 — 外层按"触发器下方可用空间"动态算, 防超出窗口被裁 (向下展开 + 内滚)
    var maxHeight: CGFloat = 280

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searchable {
                HVMUI.TextField(
                    text: $searchText,
                    placeholder: "搜索...",
                    size: .sm,
                    icon: "magnifyingglass",
                    probeID: "\(selectProbeID).search"
                )
                .padding(HVMTheme.space.sm)
                .focused($searchFocused)
            }

            if options.isEmpty {
                emptyState
            } else {
                // VStack 替 LazyVStack: .overlay 模式下 LazyVStack ideal size 会塌成 0;
                // VStack 走 content size 自然撑高, ScrollView 限 maxHeight 防超长列表撑爆.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { idx, opt in
                            row(idx: idx, option: opt)
                        }
                    }
                    .padding(.vertical, HVMTheme.space.xs)
                    .hvmHideScroller()   // 下拉内部滚动条也隐藏 (保留滚动)
                }
                .frame(maxHeight: maxHeight)
                .scrollIndicators(.hidden)
            }
        }
        .background(HVMTheme.color.bgOverlay)
        .clipShape(RoundedRectangle(cornerRadius: HVMTheme.radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HVMTheme.radius.lg)
                .stroke(HVMTheme.color.borderEmphasis, lineWidth: HVMTheme.border.hairline)
        )
        // 自家 layered shadow 让 popover "飘起来"
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        .shadow(color: .black.opacity(0.25), radius: 4,  x: 0, y: 2)
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
            // contentShape 让 hover hit 区跟整 row frame 一致 (否则只在文字 / icon 范围内)
            .contentShape(Rectangle())
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

/// Trigger 按钮的 implicit probe — <probeID>.trigger 接 .button(toggleOpen), 自动化展开/收起下拉.
private struct ProbeSelectTriggerModifier: ViewModifier {
    let probeID: String
    let label: String
    let toggle: @MainActor @Sendable () -> Void
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if !isDisabled {
            content.hvmProbe(
                id: probeID,
                label: label,
                action: .button(toggle)
            )
        } else {
            content
        }
    }
}

/// Select 主 probe — 用 .textField role (无 generic .select). 必须 @Binding selection + options
/// 才能在 getter/setter 动态算最新值 (传 snapshot 字符串则注册后不再更新).
private struct ProbeSelectModifier<Value: Hashable>: ViewModifier {
    let probeID: String
    let label: String
    @Binding var selection: Value?
    let options: [HVMUI.SelectOption<Value>]
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if !isDisabled {
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

