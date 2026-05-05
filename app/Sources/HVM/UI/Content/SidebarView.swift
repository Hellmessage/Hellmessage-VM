// SidebarView.swift
// 左栏: VM 列表卡片化. 顶部 section header (Virtual Machines + 计数), 列表项 = guest icon + 名 + 状态.
//
// 拖动重排:
//   - LazyVStack 不支持原生 .onMove (那是 List 专属), 所以走 .onDrag / .onDrop 手动实现
//   - drag payload = "hvm-vm-row:<uuid>" 字符串 (走 .text UTType, 不必声明自家 UTType)
//   - drop 解 payload, 检查 "hvm-vm-row:" 前缀防外部文本误触发
//   - drop 落在某行 → 把 source 移动到 target 之前 (尾部 sentinel 行处理"放到末尾"的情况)
//   - 落到 sentinel (LazyVStack 末尾) 当作"放到末尾"

import SwiftUI
import UniformTypeIdentifiers
import HVMBundle
import HVMCore
import HVMGuiProbe

/// 内部 reorder payload 前缀: 防外部 text drop 误触发. 完整 payload = prefix + uuid 字符串.
private let reorderPayloadPrefix = "hvm-vm-row:"

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HVMColor.bgSidebar)
    }

    // MARK: - section header

    private var header: some View {
        HStack(spacing: HVMSpace.sm) {
            Text("Virtual Machines")
                .font(HVMFont.label)
                .foregroundStyle(HVMColor.textTertiary)
            Spacer()
            Text("\(model.list.count)")
                .font(HVMFont.small.weight(.semibold))
                .foregroundStyle(HVMColor.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.lg)
        .padding(.bottom, HVMSpace.sm)
    }

    // MARK: - list

    @ViewBuilder
    private var list: some View {
        if model.list.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.list) { item in
                        let captured = item.id
                        Row(item: item,
                            isSelected: model.selectedID == item.id,
                            isRunning: item.runState == "running")
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = captured }
                            .hvmProbe(id: "sidebar.vmRow.\(item.displayName)",
                                       label: item.displayName,
                                       action: .button { model.selectedID = captured })
                            .onDrag {
                                let payload = reorderPayloadPrefix + captured.uuidString
                                return NSItemProvider(object: payload as NSString)
                            }
                            .onDrop(of: [.text], delegate: RowReorderDropDelegate(
                                target: captured,
                                model: model
                            ))
                    }
                    // 末尾 sentinel: 占满剩余宽度 + 24pt 高度, 接 drop 当作 "放到末尾"
                    Color.clear
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                        .onDrop(of: [.text], delegate: RowReorderDropDelegate(
                            target: nil,
                            model: model
                        ))
                }
                .padding(.horizontal, HVMSpace.sm)
                .padding(.bottom, HVMSpace.md)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            Text("No VMs yet")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
            Button(action: { model.showCreateWizard = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(HVMFont.smallEm)
                    Text("Create VM")
                }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.top, HVMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 单卡

private struct Row: View {
    let item: AppModel.VMListItem
    let isSelected: Bool
    let isRunning: Bool
    @State private var hover: Bool = false

    var body: some View {
        HStack(spacing: HVMSpace.sm) {
            GuestBadge(os: item.guestOS, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.displayName)
                        .font(HVMFont.bodyBold)
                        .foregroundStyle(HVMColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textSecondary)
                            .help("加密 VM (\(item.encryptionScheme?.rawValue ?? "—"))")
                    }
                }
                HStack(spacing: 5) {
                    if isRunning {
                        Circle()
                            .fill(HVMColor.statusRunning)
                            .frame(width: 6, height: 6)
                        Text("Running")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.statusRunning)
                    } else {
                        Circle()
                            .fill(HVMColor.statusStopped.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text("Stopped")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                    Text("·")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                    if item.isEncrypted {
                        Text("Encrypted")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    } else {
                        Text(GuestVisual.style(for: item.guestOS).label)
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HVMSpace.sm)
        .padding(.vertical, HVMSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .fill(isSelected ? HVMColor.bgSelected
                                 : (hover ? HVMColor.bgHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(isSelected ? HVMColor.borderAccent : Color.clear, lineWidth: 1)
        )
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.1), value: hover)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - 拖动重排 DropDelegate
//
// target == nil 表示 drop 落到末尾 sentinel; target 非 nil 表示 drop 落在某行 (插到该行前面).
// performDrop 解 NSItemProvider 拿 source UUID, 调 model.reorderList 落盘 + 同步 list.
private struct RowReorderDropDelegate: DropDelegate {
    let target: UUID?
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.text])
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String,
                  s.hasPrefix(reorderPayloadPrefix),
                  let source = UUID(uuidString: String(s.dropFirst(reorderPayloadPrefix.count))) else { return }
            DispatchQueue.main.async {
                self.applyReorder(source: source)
            }
        }
        return true
    }

    private func applyReorder(source: UUID) {
        var ids = model.list.map { $0.id }
        guard let from = ids.firstIndex(of: source) else { return }
        ids.remove(at: from)
        if let target {
            // 落到 target 行之前. target 跟 source 同一项 → 撤回插入位置 (no-op)
            if source == target {
                ids.insert(source, at: from)
                return
            }
            guard let to = ids.firstIndex(of: target) else {
                ids.insert(source, at: from)
                return
            }
            ids.insert(source, at: to)
        } else {
            // sentinel: 放末尾
            ids.append(source)
        }
        model.reorderList(ids)
    }
}
