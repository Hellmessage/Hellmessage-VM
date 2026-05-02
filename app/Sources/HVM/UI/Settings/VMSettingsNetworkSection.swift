// VMSettings 网络子区块 —— 主骨架 (hell-vm 同款, 改 HVM theme/component)
//
// 设计要点:
// - 网络改动写入 draft (VMConfig), 保存时 EditConfigDialog 把 draft 落 yaml
// - 多 NIC 折叠卡片, 默认全部折叠, 新加的自动展开
// - 模式选择用自绘下拉 (跟暗色主题一致, 不走系统 Menu)
// - vmnet daemon 状态面板在任一 NIC 走 vmnet 时显示, 一键装 / 卸 (osascript admin)
//
// 子 UI 拆到 extension 文件:
//   - VMSettingsNetworkSection+NICCard      单 NIC 卡片 / NIC 型号 / MAC 字段
//   - VMSettingsNetworkSection+ModePickers  模式下拉 / 桥接接口下拉
//   - VMSettingsNetworkSection+VmnetDaemon  vmnet daemon 状态面板与装卸

import SwiftUI
import HVMBundle
import HVMCore

struct VMSettingsNetworkSection: View {
    @Binding var draft: VMConfig
    let item: AppModel.VMListItem

    /// 多网卡卡片折叠状态
    @State var expandedNICs: Set<Int> = []
    /// 每个 NIC 的模式下拉展开状态
    @State var openModeMenus: Set<Int> = []
    /// 每个 NIC 的桥接接口下拉展开状态
    @State var openIfaceMenus: Set<Int> = []
    /// vmnet daemon 安装/卸载状态
    @State var vmnetBusy: Bool = false
    @State var vmnetError: String?
    /// 安装/卸载后 bump, 强制 vmnetDaemonPanel 重读 socket 状态
    @State var vmnetRefreshToken: UInt64 = 0

    var body: some View {
        TerminalSection("网络") {
            VStack(alignment: .leading, spacing: HVMSpace.sm) {
                ForEach(draft.networks.indices, id: \.self) { idx in
                    nicCard(at: idx)
                }
                HStack(spacing: HVMSpace.sm) {
                    Button(action: { addNIC() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("添加网卡").font(HVMFont.caption)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Text(BundleLock.isBusy(bundleURL: item.bundleURL)
                         ? "VM 运行中 — 保存的网络改动下次启动生效"
                         : "多网卡: 同 VM 同时挂不同网络 (例: shared 上网 + bridged 暴露服务)")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                    Spacer()
                }
                vmnetDaemonPanel
            }
        }
    }

    // MARK: - NIC 增删与字段更新

    func setMode(_ m: NetworkMode, at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks[idx].mode = m
        if m == .user || m == .none {
            draft.networks[idx].socketVmnetPath = nil
            draft.networks[idx].bridgedInterface = nil
        }
    }

    func updateNet(at idx: Int, _ mutate: (inout NetworkSpec) -> Void) {
        guard idx < draft.networks.count else { return }
        mutate(&draft.networks[idx])
    }

    func addNIC() {
        // 默认 virtio + user-mode NAT, MAC 自动生成
        draft.networks.append(NetworkSpec(
            mode: .user,
            macAddress: NetworkSpec.generateRandomMAC(),
            deviceModel: .virtio,
            enabled: true
        ))
        expandedNICs.insert(draft.networks.count - 1)
    }

    func removeNIC(at idx: Int) {
        guard idx < draft.networks.count else { return }
        draft.networks.remove(at: idx)
        var newSet: Set<Int> = []
        for e in expandedNICs {
            if e < idx { newSet.insert(e) }
            else if e > idx { newSet.insert(e - 1) }
        }
        expandedNICs = newSet
    }

    // MARK: - Mode 展示辅助 (跨 extension 共用)

    func displayName(of m: NetworkMode) -> String {
        switch m {
        case .user:         return "user (NAT)"
        case .vmnetShared:  return "vmnet shared"
        case .vmnetHost:    return "vmnet host-only"
        case .vmnetBridged: return "vmnet bridged"
        case .none:         return "无网络"
        }
    }

    func modeIcon(_ m: NetworkMode) -> String {
        switch m {
        case .user:         return "network"
        case .vmnetShared:  return "shared.with.you"
        case .vmnetHost:    return "house"
        case .vmnetBridged: return "antenna.radiowaves.left.and.right"
        case .none:         return "pause.circle"
        }
    }

    func modeColor(_ m: NetworkMode) -> Color {
        m == .none ? HVMColor.textTertiary : HVMColor.accent
    }

    func modeSubtitle(_ m: NetworkMode) -> String {
        switch m {
        case .user:         return "零依赖, 不支持 ICMP"
        case .vmnetShared:  return "默认 vmnet 模式 (NAT+DHCP)"
        case .vmnetHost:    return "仅宿主机互通"
        case .vmnetBridged: return "真二层桥接"
        case .none:         return "不挂载"
        }
    }
}
