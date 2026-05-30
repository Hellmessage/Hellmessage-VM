// DetailVmnetDaemonView.swift — vmnet daemon 安装/重启/卸载入口 (V6).
//
// 直接调视图无关的 VMnetSupervisor (app/Sources/HVM/Services/, 已是 public enum 无 GUI 耦合):
// installAllDaemons / restartAllDaemons / uninstallAllDaemons / presentSockets.
// 仅当 VM 有 vmnet 模式 NIC (shared/host/bridged) 时显示 — daemon 是系统级全局组件.
// 安装/重启/卸载走 osascript admin (Touch ID/密码); 重启+卸载是破坏性, 二次确认 (CLAUDE.md 约束).

#if NEW_GUI

import SwiftUI
import HVMBundle

struct DetailVmnetDaemonView: View {
    let networks: [NetworkSpec]

    @EnvironmentObject private var dialog: HVMUI.DialogPresenter
    @State private var busy = false
    @State private var error: String?
    @State private var refreshToken = 0

    private var usesVmnet: Bool {
        networks.contains {
            [.vmnetShared, .vmnetHost, .vmnetBridged].contains($0.mode)
        }
    }

    private var bridgedIfaces: [String] {
        networks.compactMap { $0.mode == .vmnetBridged ? $0.effectiveBridgedInterface : nil }
    }

    var body: some View {
        if usesVmnet {
            content
        }
    }

    private var content: some View {
        let _ = refreshToken   // 读一下建立依赖, 动作后 bump 触发 presentSockets 重读
        let sockets = VMnetSupervisor.presentSockets()
        return VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HVMUI.Divider()

            HStack(spacing: HVMTheme.space.sm) {
                Text("vmnet daemon")
                    .font(HVMTheme.font.md)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                statusChip("shared", ok: sockets.shared)
                statusChip("host", ok: sockets.host)
                ForEach(bridgedIfaces, id: \.self) { iface in
                    statusChip("bridged.\(iface)", ok: sockets.bridged.contains(iface))
                }
                Spacer()
            }

            Text("vmnet 模式需系统级 daemon (socket_vmnet, brew 安装). 安装/重启/卸载需管理员授权 (Touch ID/密码).")
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)

            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Button("安装 / 更新 daemon", variant: .primary, size: .sm,
                             disabled: busy, isLoading: busy,
                             probeID: "detail.vmnet.install") {
                    runDaemon("安装失败") {
                        try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: bridgedIfaces)
                    }
                }
                HVMUI.Button("重启", variant: .secondary, size: .sm,
                             disabled: busy, probeID: "detail.vmnet.restart") {
                    confirmThenRun(title: "重启 daemon?",
                                   message: "会断开所有已连接 VM 的网络. 用于 daemon 看似正常但桥接已死时自救.",
                                   confirmLabel: "重启",
                                   failTitle: "重启失败") {
                        try await VMnetSupervisor.restartAllDaemons()
                    }
                }
                HVMUI.Button("卸载全部", variant: .ghost, size: .sm,
                             disabled: busy, probeID: "detail.vmnet.uninstall") {
                    confirmThenRun(title: "卸载全部 daemon?",
                                   message: "移除 HVM 装的所有 vmnet daemon. vmnet 网络的 VM 将无法联网.",
                                   confirmLabel: "卸载",
                                   failTitle: "卸载失败") {
                        try await VMnetSupervisor.uninstallAllDaemons()
                    }
                }
                Spacer()
            }

            if let error {
                Text(error)
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.error)
            }
        }
    }

    private func statusChip(_ label: String, ok: Bool) -> some View {
        HVMUI.Badge(label, variant: ok ? .success : .error,
                    icon: ok ? "checkmark" : "xmark", size: .sm)
    }

    /// 跑 daemon 操作: busy → try → 失败映射 error (用户取消授权不算错)
    private func runDaemon(_ failTitle: String, _ body: @escaping () async throws -> Void) {
        Task { @MainActor in
            busy = true
            error = nil
            defer { busy = false }
            do {
                try await body()
                refreshToken += 1
            } catch let e as VMnetSupervisor.VMnetError {
                if case .userCancelled = e { return }
                self.error = "\(failTitle): \(e.localizedDescription)"
            } catch let e {
                self.error = "\(failTitle): \(e.localizedDescription)"
            }
        }
    }

    /// 破坏性操作先二次确认再跑
    private func confirmThenRun(title: String, message: String, confirmLabel: String,
                               failTitle: String, _ body: @escaping () async throws -> Void) {
        Task { @MainActor in
            let r = await dialog.confirm(title: title, message: message,
                                         confirmLabel: confirmLabel, destructive: true,
                                         probeID: "detail.vmnet.confirm")
            if case .confirmed = r { runDaemon(failTitle, body) }
        }
    }
}

#endif
