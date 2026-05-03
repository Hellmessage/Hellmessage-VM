// VMSettingsNetworkSection —— vmnet daemon 状态面板与安装/卸载
// 提权走 VMnetSupervisor (osascript with administrator privileges, Touch ID).
import SwiftUI
import HVMBundle
import HVMCore

extension VMSettingsNetworkSection {

    @ViewBuilder
    var vmnetDaemonPanel: some View {
        let vmnetNets = draft.networks.filter {
            $0.mode == .vmnetShared || $0.mode == .vmnetHost || $0.mode == .vmnetBridged
        }
        if !vmnetNets.isEmpty {
            let sockets = VMnetSupervisor.presentSockets()
            let missing = vmnetNets.compactMap { net -> String? in
                guard let p = net.effectiveSocketPath else { return nil }
                return SocketPaths.isReady(p) ? nil : p
            }
            VStack(alignment: .leading, spacing: 6) {
                LabelText("vmnet daemon")
                HStack(alignment: .top, spacing: HVMSpace.sm) {
                    Image(systemName: missing.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(HVMFont.small)
                        .foregroundStyle(missing.isEmpty ? HVMColor.statusRunning : HVMColor.statusPaused)
                    VStack(alignment: .leading, spacing: 3) {
                        if missing.isEmpty {
                            Text("所有 NIC 需要的 socket 均已就绪")
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
                    }
                    Spacer()
                }
                HStack(spacing: HVMSpace.sm) {
                    Button(action: { Task { await installVmnet() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(HVMFont.label)
                            Text(vmnetBusy ? "正在安装…" : "安装 / 更新 daemon")
                                .font(HVMFont.caption)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(vmnetBusy)

                    Button(action: { Task { await uninstallVmnet() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(HVMFont.label)
                            Text("卸载全部").font(HVMFont.caption)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(vmnetBusy)
                    Spacer()
                }
                if let err = vmnetError {
                    Text(err).font(HVMFont.small).foregroundStyle(HVMColor.danger)
                }
                Text("用户机器需先 brew install socket_vmnet. 安装 daemon 时会弹原生 Touch ID / 密码框.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(HVMSpace.sm + 2)
            .background(RoundedRectangle(cornerRadius: HVMRadius.md).fill(HVMColor.bgCard))
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.md).stroke(HVMColor.border, lineWidth: 1))
            .id(vmnetRefreshToken)  // bump 后强制重算 sockets/missing
        }
    }

    @MainActor
    private func installVmnet() async {
        vmnetBusy = true
        vmnetError = nil
        defer { vmnetBusy = false }
        do {
            // 用 effectiveBridgedInterface 保证与 UI 缺失提示 (effectiveSocketPath)
            // 的口径一致 — 空的 bridgedInterface 会 fallback 到 "en0", 不会被跳过.
            let extra = draft.networks.compactMap { $0.effectiveBridgedInterface }
            try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: extra)
            vmnetRefreshToken &+= 1
        } catch {
            vmnetError = "安装失败: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func uninstallVmnet() async {
        vmnetBusy = true
        vmnetError = nil
        defer { vmnetBusy = false }
        do {
            try await VMnetSupervisor.uninstallAllDaemons()
            vmnetRefreshToken &+= 1
        } catch {
            vmnetError = "卸载失败: \(error.localizedDescription)"
        }
    }
}
