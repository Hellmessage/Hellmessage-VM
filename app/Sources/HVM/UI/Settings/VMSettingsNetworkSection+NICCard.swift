// VMSettingsNetworkSection —— 单 NIC 卡片 + NIC 型号 + MAC 字段
import SwiftUI
import HVMBundle
import HVMCore

extension VMSettingsNetworkSection {

    // MARK: - 单块 NIC 卡片

    @ViewBuilder
    func nicCard(at idx: Int) -> some View {
        if idx < draft.networks.count {
            let expanded = expandedNICs.contains(idx)
            let enabled = draft.networks[idx].enabled
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: HVMSpace.sm) {
                    Button(action: { toggleNICExpanded(idx) }) {
                        HStack(spacing: HVMSpace.sm) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(HVMColor.textTertiary)
                                .frame(width: 10)
                            Image(systemName: "network")
                                .font(.system(size: 12))
                                .foregroundStyle(enabled ? HVMColor.accent : HVMColor.textTertiary)
                            Text("NIC \(idx)")
                                .font(HVMFont.caption.weight(.semibold))
                                .foregroundStyle(enabled ? HVMColor.textPrimary : HVMColor.textTertiary)
                            Text(nicSummary(at: idx))
                                .font(HVMFont.small)
                                .foregroundStyle(HVMColor.textSecondary.opacity(enabled ? 1.0 : 0.5))
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Toggle("", isOn: Binding(
                        get: { draft.networks[idx].enabled },
                        set: { new in draft.networks[idx].enabled = new }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(enabled ? "点击禁用此网卡 (保留配置, 启动时不挂)" : "点击启用此网卡")

                    Button(action: { removeNIC(at: idx) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(HVMColor.danger)
                            .padding(.horizontal, HVMSpace.sm).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: HVMRadius.sm).fill(HVMColor.danger.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("删除此网卡")
                }
                .padding(.horizontal, HVMSpace.md).padding(.vertical, 10)

                if expanded {
                    Rectangle().fill(HVMColor.border).frame(height: 1)
                    VStack(alignment: .leading, spacing: HVMSpace.md) {
                        networkModeMenu(at: idx)
                        nicModelPicker(at: idx)
                        let mode = draft.networks[idx].mode
                        if mode == .vmnetBridged {
                            networkVmnetOptions(at: idx)
                        }
                        networkMacField(at: idx)
                    }
                    .padding(HVMSpace.md)
                }
            }
            .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    /// 折叠状态下的摘要行
    private func nicSummary(at idx: Int) -> String {
        let net = draft.networks[idx]
        var parts: [String] = []
        if !net.enabled {
            parts.append("已禁用")
        }
        var modeStr = displayName(of: net.mode)
        if net.mode == .vmnetBridged, let iface = net.bridgedInterface, !iface.isEmpty {
            modeStr += "(\(iface))"
        }
        parts.append(modeStr)
        parts.append(net.deviceModel.rawValue)
        if net.macAddress.count >= 8 {
            parts.append("…\(net.macAddress.suffix(8))")
        }
        return parts.joined(separator: " · ")
    }

    private func toggleNICExpanded(_ idx: Int) {
        if expandedNICs.contains(idx) { expandedNICs.remove(idx) } else { expandedNICs.insert(idx) }
    }

    // MARK: - NIC 型号

    func nicModelPicker(at idx: Int) -> some View {
        let current = draft.networks[idx].deviceModel
        return VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("NIC 型号")
            HStack(spacing: HVMSpace.xs) {
                nicChip(.virtio,  title: "virtio",  subtitle: "Linux 最快", current: current, idx: idx)
                nicChip(.e1000e,  title: "e1000e",  subtitle: "Win 开箱",   current: current, idx: idx)
                nicChip(.rtl8139, title: "rtl8139", subtitle: "老系统兜底", current: current, idx: idx)
            }
        }
    }

    private func nicChip(_ m: NICModel, title: String, subtitle: String,
                         current: NICModel, idx: Int) -> some View {
        let selected = current == m
        return Button(action: { updateNet(at: idx) { $0.deviceModel = m } }) {
            VStack(spacing: 3) {
                Text(title)
                    .font(HVMFont.caption.weight(.semibold))
                    .foregroundStyle(selected ? HVMColor.textPrimary : HVMColor.textSecondary)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: HVMRadius.sm)
                .fill(selected ? HVMColor.accentMuted : HVMColor.bgCardHi))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm)
                .stroke(selected ? HVMColor.borderAccent : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - MAC 字段

    func networkMacField(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("MAC 地址")
            HStack(spacing: HVMSpace.sm) {
                HVMTextField(
                    "52:54:00:xx:xx:xx",
                    text: Binding(
                        get: { draft.networks[idx].macAddress },
                        set: { v in updateNet(at: idx) { $0.macAddress = v } }
                    )
                )
                Button(action: {
                    updateNet(at: idx) { $0.macAddress = NetworkSpec.generateRandomMAC() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("重新生成").font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}
