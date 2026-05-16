// StatusBarVmnet.swift
// 状态栏 vmnet daemon 快捷入口 (在右下"缩略图"按钮左边).
//
// 设计:
//   - 状态栏按钮: 网络图标 + "vmnet" + 状态色 (绿=就绪 / 黄=部分缺失).
//   - 点击弹 HVMPopupPanel (NSPanel-based 自绘 popup), 内容 = "vmnet daemon" 面板等价视图:
//       · 状态文字 (就绪 / 缺失 socket 列表)
//       · shared / host / bridged readiness 行
//       · [安装 / 更新 daemon] / [卸载全部] 两按钮
//       · brew install socket_vmnet 提示
//   - 安装时的 bridged 接口集合 = 汇总 model.list 里所有 VM config 的 effectiveBridgedInterface
//     (加密未解锁的 VM .config 为 nil, 自动跳过 — 不影响 shared/host 安装).
//
// 与 VMSettingsNetworkSection+VmnetDaemon 的差异:
//   - 那个面板在"编辑配置 → 网络"里, 只看当前 VM 的 networks (draft.networks)
//   - 状态栏快捷入口面向"全机器" — 汇总所有 VM
//
// 为什么用 HVMPopupPanel 而不是 NSPopover (历史 BUG 教训):
//   - 早期版本用 NSPopover + .transient. 测试发现: VM 未启动时 popover 正常弹;
//     VM 启动后 (VZ/QEMU 显示 NSView 进入主窗口, 抢 first responder) 点击 vmnet
//     按钮无任何反应 — NSPopover 的 .transient 行为跟主窗口 key/main 状态耦合太紧
//   - 切到 HVMPopupPanel (NSPanel + .nonactivatingPanel + 手工 click-outside 监听)
//     与主窗口焦点解耦, 跟 HVMFormSelect 用同一套, VM 跑没跑都行

import SwiftUI
import AppKit
import HVMCore

@MainActor
struct HVMStatusBarVmnetButton: View {
    @Bindable var model: AppModel
    /// 弹出 popup 后, 让按钮和 popup 内部都能 bump 这个值刷新视图状态
    @State private var refreshToken: UInt = 0
    /// 弹出 popup 时拿 anchor NSView 做相对定位
    @State private var anchorRef = HVMAnchorView.Holder()
    /// 自家 popup 控制器, 必须 retain 住, 否则关闭事件监听器跟 panel 一起 dealloc
    @State private var popup = HVMPopupPanel()

    var body: some View {
        let sockets = VMnetSupervisor.presentSockets()
        let needed = neededInterfaces()
        let missing = computeMissing(sockets: sockets, needed: needed)
        let allOk = missing.isEmpty

        Button(action: { showPopup() }) {
            HStack(spacing: 4) {
                Image(systemName: allOk ? "network" : "exclamationmark.triangle.fill")
                    .font(HVMFont.small)
                    .foregroundStyle(allOk ? HVMColor.statusRunning : HVMColor.statusPaused)
                Text("vmnet")
                    .font(HVMFont.small)
                    .foregroundStyle(allOk ? HVMColor.textSecondary : HVMColor.textPrimary.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .background(HVMAnchorView(ref: anchorRef))
        .id(refreshToken)
        .help(allOk
              ? "vmnet daemon 已就绪 — 点击查看详情 / 重装"
              : "vmnet daemon 缺失 socket — 点击安装")
        .hvmProbe(id: "statusbar.button.vmnetShortcut",
                   label: allOk ? "Vmnet OK" : "Vmnet Missing",
                   action: .button { showPopup() })
    }

    /// 汇总 model.list 里所有 VM config 的 bridged 接口, 去重排序.
    /// 加密未解锁 VM 的 config 为 nil → 自动跳过 (不影响 shared/host).
    private func neededInterfaces() -> [String] {
        var s = Set<String>()
        for item in model.list {
            guard let cfg = item.config else { continue }
            for net in cfg.networks {
                if let i = net.effectiveBridgedInterface { s.insert(i) }
            }
        }
        return s.sorted()
    }

    /// 缺失 socket 计算: shared/host 总是希望就绪; bridged 仅在 needed 列表里时才算缺失
    /// (用户没用 bridged 时不会因为系统没装 bridged daemon 而报黄).
    private func computeMissing(
        sockets: (shared: Bool, host: Bool, bridged: [String]),
        needed: [String]
    ) -> [String] {
        var missing: [String] = []
        if !sockets.shared { missing.append("shared") }
        if !sockets.host { missing.append("host") }
        let bridgedReady = Set(sockets.bridged)
        for iface in needed where !bridgedReady.contains(iface) {
            missing.append("bridged.\(iface)")
        }
        return missing
    }

    private func showPopup() {
        guard let anchor = anchorRef.view else { return }
        popup.present(
            anchor: anchor,
            maxHeight: 260,
            preferredWidth: 320,
            rightAligned: true,
            content: {
                StatusBarVmnetPopup(model: model) { _ in
                    // 安装/卸载完成后让外层按钮重渲, 拉新 sockets 状态
                    Task { @MainActor in
                        self.refreshToken &+= 1
                    }
                }
            },
            onDismiss: {
                // 关闭后也刷新一次主按钮 (popup 内部已 bump 自己的 token, 外层这里再 bump 一次保险)
                Task { @MainActor in
                    self.refreshToken &+= 1
                }
            }
        )
    }
}

// MARK: - Popup 内容

@MainActor
private struct StatusBarVmnetPopup: View {
    @Bindable var model: AppModel
    /// 安装/卸载完成回调, 通知外层按钮刷新状态
    let onChange: (Bool) -> Void

    @State private var busy: Bool = false
    @State private var errorText: String? = nil
    /// 内部刷新 token: 安装/卸载完成时 bump, 强制重渲取最新 sockets
    @State private var refreshToken: UInt = 0

    var body: some View {
        let sockets = VMnetSupervisor.presentSockets()
        let needed = neededInterfaces()
        let missing = computeMissing(sockets: sockets, needed: needed)
        let allOk = missing.isEmpty

        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            // 标题
            HStack(spacing: HVMSpace.xs) {
                Image(systemName: "network")
                    .font(HVMFont.label)
                    .foregroundStyle(HVMColor.textSecondary)
                Text("vmnet daemon")
                    .font(HVMFont.label.weight(.semibold))
                    .foregroundStyle(HVMColor.textPrimary)
            }

            // 状态行
            HStack(alignment: .top, spacing: HVMSpace.sm) {
                Image(systemName: allOk ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(HVMFont.small)
                    .foregroundStyle(allOk ? HVMColor.statusRunning : HVMColor.statusPaused)
                VStack(alignment: .leading, spacing: 3) {
                    if allOk {
                        Text(needed.isEmpty
                             ? "shared + host 已就绪"
                             : "所有 NIC 需要的 socket 均已就绪")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textSecondary)
                    } else {
                        Text("缺失 socket: \(missing.joined(separator: ", "))")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textPrimary.opacity(0.9))
                    }
                    Text("已装: shared=\(sockets.shared ? "✓" : "✗") · host=\(sockets.host ? "✓" : "✗") · bridged=[\(sockets.bridged.joined(separator: ", "))]")
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 操作按钮
            HStack(spacing: HVMSpace.sm) {
                Button(action: { Task { await installVmnet() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(HVMFont.label)
                        Text(busy ? "正在安装…" : "安装 / 更新 daemon")
                            .font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(busy)
                .hvmProbe(id: "popover.vmnet.button.install",
                           label: busy ? "Installing" : "Install",
                           action: .button { Task { await installVmnet() } })

                Button(action: { Task { await uninstallVmnet() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(HVMFont.label)
                        Text("卸载全部").font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle(destructive: true))
                .disabled(busy)
                .hvmProbe(id: "popover.vmnet.button.uninstall",
                           label: "Uninstall",
                           action: .button { Task { await uninstallVmnet() } })
            }

            if let err = errorText {
                Text(err)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 提示
            Text("用户机器需先 brew install socket_vmnet. 安装 daemon 时会弹原生 Touch ID / 密码框.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HVMSpace.md)
        .background(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .fill(HVMColor.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HVMRadius.md, style: .continuous)
                .stroke(HVMColor.border, lineWidth: 1)
        )
        .id(refreshToken)
    }

    private func neededInterfaces() -> [String] {
        var s = Set<String>()
        for item in model.list {
            guard let cfg = item.config else { continue }
            for net in cfg.networks {
                if let i = net.effectiveBridgedInterface { s.insert(i) }
            }
        }
        return s.sorted()
    }

    private func computeMissing(
        sockets: (shared: Bool, host: Bool, bridged: [String]),
        needed: [String]
    ) -> [String] {
        var missing: [String] = []
        if !sockets.shared { missing.append("shared") }
        if !sockets.host { missing.append("host") }
        let bridgedReady = Set(sockets.bridged)
        for iface in needed where !bridgedReady.contains(iface) {
            missing.append("bridged.\(iface)")
        }
        return missing
    }

    @MainActor
    private func installVmnet() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: neededInterfaces())
            refreshToken &+= 1
            onChange(true)
        } catch {
            errorText = "安装失败: \(error.localizedDescription)"
            onChange(false)
        }
    }

    @MainActor
    private func uninstallVmnet() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await VMnetSupervisor.uninstallAllDaemons()
            refreshToken &+= 1
            onChange(true)
        } catch {
            errorText = "卸载失败: \(error.localizedDescription)"
            onChange(false)
        }
    }
}
