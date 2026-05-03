// VMSettingsNetworkSection —— 模式下拉 + 桥接接口下拉
// 两个自绘下拉都是暗色主题定制, 不用系统 Menu.
import SwiftUI
import HVMBundle
import HVMCore

extension VMSettingsNetworkSection {

    // MARK: - 模式下拉 (自绘)

    func networkModeMenu(at idx: Int) -> some View {
        let current = draft.networks[idx].mode
        let isOpen = openModeMenus.contains(idx)
        return VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("模式")
            Button(action: { toggleModeMenu(idx) }) {
                HStack {
                    Image(systemName: modeIcon(current))
                        .foregroundStyle(modeColor(current))
                        .font(HVMFont.caption)
                    Text(displayName(of: current))
                        .foregroundStyle(HVMColor.textPrimary)
                        .font(HVMFont.caption.weight(.medium))
                    Text(modeSubtitle(current))
                        .foregroundStyle(HVMColor.textTertiary)
                        .font(HVMFont.small)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(HVMColor.textTertiary)
                        .font(HVMFont.tiny)
                }
                .padding(.horizontal, HVMSpace.md).padding(.vertical, HVMSpace.sm)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCardHi))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md)
                    .stroke(isOpen ? HVMColor.borderAccent : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 4) {
                    modeOption(.user,         title: "user (NAT)",        subtitle: "QEMU SLIRP / VZ NAT, 零依赖, 不支持 ICMP/ping", current: current, idx: idx)
                    modeOption(.vmnetShared,  title: "vmnet · shared",    subtitle: "NAT + DHCP (socket_vmnet 默认模式)",            current: current, idx: idx)
                    modeOption(.vmnetHost,    title: "vmnet · host-only", subtitle: "仅宿主机互通, 无外网",                          current: current, idx: idx)
                    modeOption(.vmnetBridged, title: "vmnet · bridged",   subtitle: "真二层桥接, 获取同局域网 IP",                    current: current, idx: idx)
                    Rectangle().fill(HVMColor.border).frame(height: 1).padding(.vertical, HVMSpace.v2)
                    modeOption(.none,         title: "暂时禁用",           subtitle: "保留配置, 启动时不挂这块 NIC",                   current: current, idx: idx)
                }
                .padding(HVMSpace.buttonPadV6)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
            }
        }
    }

    private func modeOption(_ mode: NetworkMode,
                            title: String, subtitle: String,
                            current: NetworkMode, idx: Int) -> some View {
        let selected = current == mode
        return Button(action: {
            setMode(mode, at: idx)
            openModeMenus.remove(idx)
        }) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(HVMFont.body)
                    .foregroundStyle(selected ? HVMColor.accent : HVMColor.textTertiary)
                Image(systemName: modeIcon(mode))
                    .font(HVMFont.small)
                    .foregroundStyle(selected ? modeColor(mode) : HVMColor.textTertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(HVMFont.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? HVMColor.textPrimary : HVMColor.textSecondary)
                    Text(subtitle)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, HVMSpace.sm + 2).padding(.vertical, HVMSpace.buttonPadV7)
            .background(RoundedRectangle(cornerRadius: HVMRadius.sm)
                .fill(selected ? HVMColor.accentMuted : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleModeMenu(_ idx: Int) {
        if openModeMenus.contains(idx) { openModeMenus.remove(idx) } else { openModeMenus.insert(idx) }
    }

    // MARK: - 桥接接口选择

    @ViewBuilder
    func networkVmnetOptions(at idx: Int) -> some View {
        let mode = draft.networks[idx].mode
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            if mode == .vmnetBridged {
                LabelText("桥接网卡")
                bridgedInterfacePicker(at: idx)
            }
        }
    }

    private func bridgedInterfacePicker(at idx: Int) -> some View {
        let ifaces = HostNetworkInterfaces.list()
        let current = draft.networks[idx].bridgedInterface ?? HostNetworkInterfaces.recommendedDefault()
        let isOpen = openIfaceMenus.contains(idx)
        return VStack(alignment: .leading, spacing: 4) {
            Button(action: { toggleIfaceMenu(idx) }) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(HVMColor.accent)
                        .font(HVMFont.caption)
                    Text(labelFor(iface: current, among: ifaces))
                        .foregroundStyle(HVMColor.textPrimary)
                        .font(HVMFont.caption.weight(.medium))
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundStyle(HVMColor.textTertiary)
                        .font(HVMFont.tiny)
                }
                .padding(.horizontal, HVMSpace.md).padding(.vertical, HVMSpace.sm)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCardHi))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md)
                    .stroke(isOpen ? HVMColor.borderAccent : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(spacing: 2) {
                    if ifaces.isEmpty {
                        Text("(扫描不到可桥接接口)")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, HVMSpace.sm + 2).padding(.vertical, HVMSpace.buttonPadV6)
                    } else {
                        ForEach(ifaces, id: \.id) { iface in
                            ifaceOption(iface, current: current, idx: idx)
                        }
                    }
                }
                .padding(HVMSpace.buttonPadV6)
                .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
            }
        }
    }

    private func ifaceOption(_ iface: HostNetworkInterface,
                             current: String, idx: Int) -> some View {
        let selected = iface.name == current
        return Button(action: {
            updateNet(at: idx) { $0.bridgedInterface = iface.name }
            openIfaceMenus.remove(idx)
        }) {
            HStack(spacing: HVMSpace.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(HVMFont.caption)
                    .foregroundStyle(selected ? HVMColor.accent : HVMColor.textTertiary)
                Circle()
                    .fill(iface.isActive ? HVMColor.statusRunning : HVMColor.textTertiary)
                    .frame(width: 6, height: 6)
                Text(iface.name)
                    .font(HVMFont.mono.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? HVMColor.textPrimary : HVMColor.textSecondary)
                if let ip = iface.ipv4 {
                    Text(ip)
                        .font(HVMFont.monoSmall)
                        .foregroundStyle(HVMColor.textTertiary)
                } else {
                    Text("(未连接)")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, HVMSpace.sm + 2).padding(.vertical, HVMSpace.buttonPadV6)
            .background(RoundedRectangle(cornerRadius: HVMRadius.sm)
                .fill(selected ? HVMColor.accentMuted : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleIfaceMenu(_ idx: Int) {
        if openIfaceMenus.contains(idx) { openIfaceMenus.remove(idx) } else { openIfaceMenus.insert(idx) }
    }

    private func labelFor(iface name: String, among ifaces: [HostNetworkInterface]) -> String {
        if let hit = ifaces.first(where: { $0.name == name }) { return hit.displayLabel }
        return "\(name) — (当前不存在)"
    }
}
