// HVMUISelect.swift — 新 GUI 下拉选择 (PR-C4)
//
// 自家绘制 (不用 NSPopUpButton / NSMenu / SwiftUI .popover), trigger 复用
// HVMUI.FieldChrome, 下拉用 ZStack overlay 浮窗 — 无系统 vibrancy / arrow /
// 阴影侵入, 完全自家绘 (bgOverlay + 边框 + 圆角 lg + 自家 shadow).
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

/// 全局 select 协调器 — 保证一次最多一个下拉框打开. 每个 Select 持 UUID,
/// openPopover() 时调 coordinator.openSelectID = self.id, 其他 Select 监听
/// .onChange 发现不是自己的 ID 就强制关闭 isOpen.
/// @Observable singleton 让 SwiftUI 自动追踪 mutation 触发 re-render.
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
    /// 每个 Select 唯一 ID, 给 SelectCoordinator 做"当前打开的 select"识别用.
    /// @State 让它在 view 生命周期内稳定 (普通 let 在 SwiftUI struct 重建时也稳定但
    /// 用 @State 显示意图: "这是 view 内部状态而不是 props").
    @State private var instanceID = UUID()
    /// 全局协调器 ref (singleton, MainActor isolated).
    private let coordinator = SelectCoordinator.shared

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
                // trigger zIndex 高于 errorMessage, 让 trigger 的 overlay popover
                // 浮在 errorMessage 之上 (修 "error 字段下拉被红字遮挡" bug)
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

    /// 切换 popover 打开 / 关闭. trigger button 跟 trigger probe (<probeID>.trigger)
    /// 都调它. hvm-dbg gui click <probeID>.trigger 自动化测下拉展开.
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
            // 内化 padding + frame + contentShape, 让 button hit test 覆盖整个 padding
            // 区域 (修 "点击中间不显示下拉" bug). Spacer(minLength: 0) + frame maxWidth
            // 让 HStack 撑满 trigger 宽度.
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
            probeID: probeID.map { "\($0).trigger" },
            label: (label ?? placeholder) + " (打开/关闭下拉)",
            toggle: { toggleOpen() },
            isDisabled: isDisabled
        ))
        // popover 用 .overlay(alignment:) 而不是 ZStack child — overlay 不参与
        // 父 view frame 计算, popover 完全脱离 layout flow 浮在 trigger 下方,
        // 不会顶下面 fieldRow / sectionCard / VStack sibling. 配合外层 zIndex
        // 反向让 popover 视觉压在所有下方控件之上.
        .overlay(alignment: .topLeading) {
            if isOpen {
                PopoverContent(
                    options: filteredOptions,
                    searchable: searchable,
                    searchText: $searchText,
                    highlightedIndex: $highlightedIndex,
                    currentValue: selection,
                    onSelect: selectOption,
                    onClose: { isOpen = false }
                )
                // popover 宽度 = trigger 宽度: .frame(maxWidth: .infinity) +
                // fixedSize(horizontal: false) 让 horizontal 受 .overlay 容器
                // (即 trigger frame) 约束, popover 自然撑满 trigger 宽度.
                // fixedSize(vertical: true) 让 vertical 用 content ideal size
                // (ScrollView/VStack 能正确撑高).
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
                // VStack 替 LazyVStack: .overlay 模式下 LazyVStack ideal size 算不
                // 出会塌成 0; VStack 走 content size 自然撑高. ScrollView 仍包裹
                // 限 maxHeight 280 防超长选项列表撑爆.
                ScrollView {
                    VStack(spacing: 0) {
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
                .stroke(HVMTheme.color.borderEmphasis, lineWidth: HVMTheme.border.hairline)
        )
        // 自家 layered shadow — 让 popover 视觉"飘起来", 不依赖系统 NSPopover
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
            // contentShape 让 hover hit 区跟整 row frame 一致 (修 "空白区域移动
            // 不变色" bug). 否则 hover 只在 HStack content (文字 / icon) 范围内.
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

/// Trigger 按钮的 implicit probe — <probeID>.trigger 接 .button(toggleOpen).
/// 让 hvm-dbg gui click <probeID>.trigger 能展开/收起下拉, 自动化测下拉内容用.
private struct ProbeSelectTriggerModifier: ViewModifier {
    let probeID: String?
    let label: String
    let toggle: @MainActor @Sendable () -> Void
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if let probeID, !isDisabled {
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

/// Select 主 probe — 用 .textField role (ProbeAction 没 generic .select).
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
