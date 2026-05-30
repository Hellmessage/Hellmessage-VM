// DetailNetworkSection.swift — 详情页网络 section (NIC 列表 + 展开编辑, V5).
//
// 多网卡铺路: 每个 NIC 一个紧凑行 (网卡N | 模式 badge | MAC | 桥接接口 | 启用开关 | 删除),
// 点击行展开编辑表单 (模式/设备型号/MAC/桥接接口). 标题右侧 [添加网卡].
// 编辑 networks draft (绑定自 DetailOverviewView), 统一 saveFooter 保存.

#if NEW_GUI

import SwiftUI
import HVMBundle
import HVMCore
import HVMGuiProbe

struct DetailNetworkSection: View {
    @Binding var networks: [NetworkSpec]
    let editable: Bool

    @EnvironmentObject private var dialog: HVMUI.DialogPresenter
    @State private var expanded: Set<Int> = []
    @State private var interfaces: [HostNetworkInterface] = []

    var body: some View {
        HVMUI.Section("网络", headerTrailing: {
            if editable {
                HVMUI.Button("添加网卡", variant: .primary, icon: "plus", size: .sm,
                             probeID: "detail.network.add") {
                    networks.append(NetworkSpec(mode: .user,
                                                macAddress: NetworkSpec.generateRandomMAC()))
                    expanded = []
                }
            }
        }) {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                if networks.isEmpty {
                    Text("无网卡")
                        .font(HVMTheme.font.sm)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                } else {
                    ForEach(networks.indices, id: \.self) { i in
                        nicItem(i)
                    }
                }
            }
        }
        .onAppear { interfaces = HostNetworkInterfaces.list() }
    }

    // MARK: - NIC item (紧凑行 + 展开编辑)

    @ViewBuilder
    private func nicItem(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(i)
            if expanded.contains(i) {
                HVMUI.Divider()
                    .padding(.vertical, HVMTheme.space.sm)
                nicEditor(i)
            }
        }
        .padding(HVMTheme.space.md)
        .background(
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .fill(HVMTheme.color.bgBase)
                .overlay(
                    RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                        .stroke(HVMTheme.color.borderDefault, lineWidth: HVMTheme.border.hairline)
                )
        )
    }

    private func summaryRow(_ i: Int) -> some View {
        HStack(spacing: HVMTheme.space.md) {
            // 左侧概要 — 点击展开/收起
            SwiftUI.Button {
                toggleExpand(i)
            } label: {
                HStack(spacing: HVMTheme.space.sm) {
                    Image(systemName: expanded.contains(i) ? "chevron.down" : "chevron.right")
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.textTertiary)
                    Text("网卡\(i + 1)")
                        .font(HVMTheme.font.md)
                        .foregroundStyle(HVMTheme.color.textPrimary)
                    HVMUI.Badge(modeLabel(networks[i].mode), variant: .neutral, size: .sm)
                    Text(networks[i].macAddress)
                        .font(HVMTheme.font.monoSm)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                        .lineLimit(1)
                    if networks[i].mode == .vmnetBridged,
                       let f = networks[i].bridgedInterface, !f.isEmpty {
                        HVMUI.Badge(f, variant: .info, size: .sm)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hvmProbe(id: "detail.network.\(i).item", label: "网卡\(i + 1)",
                      action: .button { toggleExpand(i) })

            // 右侧控件 — 启用开关 + 删除
            HVMUI.Toggle("", isOn: bind(i, \.enabled), size: .sm,
                         disabled: !editable,
                         probeID: "detail.network.\(i).enabled")
            HVMUI.Button(icon: "trash", variant: .ghost, size: .sm,
                         disabled: !editable,
                         probeID: "detail.network.\(i).delete") {
                confirmDeleteNIC(i)
            }
        }
    }

    @ViewBuilder
    private func nicEditor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(alignment: .top, spacing: HVMTheme.space.md) {
                HVMUI.Select("模式", selection: bind(i, \.mode),
                             options: NetworkMode.allCases.map {
                                 .init(value: $0, label: modeLabel($0))
                             },
                             disabled: !editable,
                             probeID: "detail.network.\(i).mode")
                    .frame(maxWidth: 220)
                HVMUI.Select("设备型号", selection: bind(i, \.deviceModel),
                             options: NICModel.allCases.map {
                                 .init(value: $0, label: $0.rawValue)
                             },
                             disabled: !editable,
                             probeID: "detail.network.\(i).device")
                    .frame(maxWidth: 160)
                Spacer()
            }
            .zIndex(2)

            HStack(alignment: .bottom, spacing: HVMTheme.space.sm) {
                HVMUI.TextField("MAC 地址", text: bind(i, \.macAddress),
                                placeholder: "52:54:00:xx:xx:xx",
                                errorMessage: NetworkSpec.isValidMAC(networks[i].macAddress)
                                    ? nil : "MAC 格式错 (xx:xx:xx:xx:xx:xx)",
                                disabled: !editable,
                                probeID: "detail.network.\(i).mac")
                    .frame(maxWidth: 280)
                HVMUI.Button(icon: "shuffle", variant: .secondary,
                             disabled: !editable,
                             probeID: "detail.network.\(i).mac.random") {
                    networks[i].macAddress = NetworkSpec.generateRandomMAC()
                }
                .frame(width: 36, height: 36)   // 跟输入框 (.md=36) 等高
            }

            if networks[i].mode == .vmnetBridged {
                HVMUI.Select("桥接接口", selection: bindOpt(i, \.bridgedInterface),
                             options: interfaces.map {
                                 .init(value: $0.name, label: $0.displayLabel)
                             },
                             placeholder: "选择物理接口...",
                             errorMessage: (networks[i].bridgedInterface ?? "").isEmpty
                                 ? "桥接模式需选物理接口" : nil,
                             disabled: !editable,
                             probeID: "detail.network.\(i).bridged")
                    .frame(maxWidth: 360)
                    .zIndex(1)
            }
        }
    }

    // MARK: - helpers

    private func toggleExpand(_ i: Int) {
        if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) }
    }

    /// 删除网卡 — 破坏性操作走二次确认 (CLAUDE.md 约束)
    private func confirmDeleteNIC(_ i: Int) {
        Task { @MainActor in
            let r = await dialog.confirm(
                title: "删除网卡?",
                message: "网卡\(i + 1) 将被移除 (保存后生效).",
                confirmLabel: "删除",
                destructive: true,
                probeID: "detail.network.\(i).delete.confirm"
            )
            if case .confirmed = r, networks.indices.contains(i) {
                networks.remove(at: i)
                expanded = []
            }
        }
    }

    private func bind<T>(_ i: Int, _ kp: WritableKeyPath<NetworkSpec, T>) -> Binding<T> {
        Binding(get: { networks[i][keyPath: kp] },
                set: { networks[i][keyPath: kp] = $0 })
    }

    private func bindOpt(_ i: Int, _ kp: WritableKeyPath<NetworkSpec, String?>) -> Binding<String?> {
        Binding(get: { networks[i][keyPath: kp] },
                set: { networks[i][keyPath: kp] = $0 })
    }

    private func modeLabel(_ m: NetworkMode) -> String {
        switch m {
        case .user:         return "NAT"
        case .vmnetShared:  return "vmnet 共享"
        case .vmnetHost:    return "vmnet host"
        case .vmnetBridged: return "vmnet 桥接"
        case .none:         return "无网络"
        }
    }
}

#endif
