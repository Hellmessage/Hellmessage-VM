// VmnetDaemonCard.swift
// vmnet daemon 状态面板 — 独立 View, 不依赖 VMSettingsNetworkSection.
// 用于 EditConfigDialog 等"只要看 daemon 状态不要 NIC 编辑"的场景.
//
// 提权走 VMnetSupervisor.installAllDaemons / uninstall / restart (osascript admin Touch ID).

import SwiftUI
import HVMBundle
import HVMCore

struct VmnetDaemonCard: View {
    /// 用来计算"哪些 socket 需要就绪". 走 networks 里 vmnet 模式的 NIC.
    /// 用 binding 是为了写期间能随 NIC 改动刷新; 这里实际不修改 networks.
    @Binding var networks: [NetworkSpec]

    @State private var busy: Bool = false
    @State private var error: String? = nil
    @State private var refreshToken: UInt64 = 0

    var body: some View {
        let vmnetNets = networks.filter {
            $0.mode == .vmnetShared || $0.mode == .vmnetHost || $0.mode == .vmnetBridged
        }
        // 当前 VM 不走 vmnet → 不显示这张卡 (跟原 VMSettingsNetworkSection 同款判断)
        if !vmnetNets.isEmpty {
            content(vmnetNets: vmnetNets)
        }
    }

    @ViewBuilder
    private func content(vmnetNets: [NetworkSpec]) -> some View {
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
                Button(action: { Task { await install() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield").font(HVMFont.label)
                        Text(busy ? "正在安装…" : "安装 / 更新 daemon").font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(busy)

                Button(action: { Task { await restart() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise.circle").font(HVMFont.label)
                        Text(busy ? "处理中…" : "重启 daemon").font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(busy)
                .help("daemon 看起来好但 bridge 死了时用 — 会断已连 VM 的网络")

                Button(action: { Task { await uninstall() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(HVMFont.label)
                        Text("卸载全部").font(HVMFont.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(busy)
                Spacer()
            }
            if let err = error {
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
        .id(refreshToken)
    }

    @MainActor
    private func install() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let extra = networks.compactMap { $0.effectiveBridgedInterface }
            try await VMnetSupervisor.installAllDaemons(extraBridgedInterfaces: extra)
            refreshToken &+= 1
        } catch {
            self.error = "安装失败: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func uninstall() async {
        busy = true; error = nil; defer { busy = false }
        do {
            try await VMnetSupervisor.uninstallAllDaemons()
            refreshToken &+= 1
        } catch {
            self.error = "卸载失败: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func restart() async {
        busy = true; error = nil; defer { busy = false }
        do {
            try await VMnetSupervisor.restartAllDaemons()
            refreshToken &+= 1
        } catch {
            self.error = "重启失败: \(error.localizedDescription)"
        }
    }
}
