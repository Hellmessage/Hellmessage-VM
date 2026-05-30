// DetailBootSection.swift — 详情页 ISO & 启动 section (V7).
//
// ISO 挂载/弹出 + 启动方式 (ISO 安装 / 仅硬盘) + Windows 三态装机推进. 这些字段相互耦合
// (改 ISO 自动取消 bootFromDiskOnly 等), 故不走 draft/saveForm, 用离散按钮即时 saveConfig
// (跟磁盘 section 同款即时动作), 避免 free toggle 进非法中间态. 复刻老 GUI DetailBars 逻辑.
//
// 后端/guest 适配:
//   - macOS guest: 走 IPSW + VZMacOSInstaller, 无 ISO 概念 → 整 section 不显示
//   - Linux: [选 ISO] 安装 → 装完 [安装完成] 切仅硬盘
//   - Windows: [选 ISO] 装 OS → [安装完成] (仅硬盘 ramfb) → guest 内装驱动 → [驱动安装完成]
//     (切 hvm-gpu-ramfb-pci 走 viogpudo)
// 仅 stopped 可改 (boot/ISO 是启动期拍板, 运行中改无意义).


import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HVMControl
import HVMBundle

struct DetailBootSection: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store

    private var cfg: VMConfig? { vm.config }
    private var editable: Bool { vm.runState == .stopped }

    var body: some View {
        if let cfg {
            HVMUI.Section("ISO & 启动",
                          description: editable ? nil : "停止 VM 后可改") {
                VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                    statusRows(cfg)
                    if vm.guestOS == .windows {
                        winStageIndicator(cfg)
                    }
                    actionRow(cfg)
                }
            }
        }
    }

    // MARK: - 状态行

    @ViewBuilder
    private func statusRows(_ cfg: VMConfig) -> some View {
        // 启动方式
        HStack(alignment: .top, spacing: HVMTheme.space.md) {
            Text("启动方式")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .frame(width: 64, alignment: .leading)
            HVMUI.Badge(cfg.bootFromDiskOnly ? "从硬盘启动" : "从 ISO 安装",
                        variant: cfg.bootFromDiskOnly ? .success : .info,
                        icon: cfg.bootFromDiskOnly ? "internaldrive" : "opticaldisc",
                        size: .sm)
            Spacer(minLength: 0)
        }
        // ISO 路径
        HStack(alignment: .top, spacing: HVMTheme.space.md) {
            Text("ISO")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(cfg.installerISO ?? "未挂载")
                .font(HVMTheme.font.monoSm)
                .foregroundStyle(cfg.installerISO == nil
                                 ? HVMTheme.color.textTertiary : HVMTheme.color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Windows 三态指示器

    /// 装机中 → 装好待装驱动 → 驱动就绪. 高亮当前阶段.
    @ViewBuilder
    private func winStageIndicator(_ cfg: VMConfig) -> some View {
        let stage = winStage(cfg)   // 0=装机中 1=待装驱动 2=就绪
        HStack(spacing: HVMTheme.space.sm) {
            stageChip("① 装机中", active: stage == 0, done: stage > 0)
            chevron
            stageChip("② 待装驱动", active: stage == 1, done: stage > 1)
            chevron
            stageChip("③ 驱动就绪", active: stage == 2, done: false)
            Spacer(minLength: 0)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(HVMTheme.font.xs)
            .foregroundStyle(HVMTheme.color.textTertiary)
    }

    private func stageChip(_ label: String, active: Bool, done: Bool) -> some View {
        Text(label)
            .font(HVMTheme.font.xs)
            .foregroundStyle(active ? HVMTheme.color.textPrimary
                             : (done ? HVMTheme.color.success : HVMTheme.color.textTertiary))
            .padding(.horizontal, HVMTheme.space.sm)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: HVMTheme.radius.sm)
                    .fill(active ? HVMTheme.color.bgRaised : Color.clear)
            )
    }

    /// 0=装机中(!bootFromDiskOnly) 1=待装驱动(bootFromDiskOnly && !drivers) 2=就绪(both)
    private func winStage(_ cfg: VMConfig) -> Int {
        if !cfg.bootFromDiskOnly { return 0 }
        return cfg.windowsDriversInstalled ? 2 : 1
    }

    // MARK: - 动作按钮

    @ViewBuilder
    private func actionRow(_ cfg: VMConfig) -> some View {
        HStack(spacing: HVMTheme.space.sm) {
            HVMUI.Button(cfg.installerISO != nil ? "更换 ISO" : "选择 ISO",
                         variant: .secondary, icon: "opticaldisc", size: .sm,
                         disabled: !editable, probeID: "detail.boot.selectISO") {
                selectISO()
            }
            if cfg.installerISO != nil {
                HVMUI.Button("弹出 ISO", variant: .ghost, icon: "eject", size: .sm,
                             disabled: !editable, probeID: "detail.boot.ejectISO") {
                    ejectISO()
                }
            }

            // 装机推进 (Windows 三态 / Linux 两态)
            if vm.guestOS == .windows {
                if !cfg.bootFromDiskOnly, cfg.installerISO != nil {
                    HVMUI.Button("安装完成", variant: .primary, icon: "checkmark", size: .sm,
                                 disabled: !editable, probeID: "detail.boot.installed") {
                        store.saveConfig(vm) {
                            $0.bootFromDiskOnly = true
                            $0.windowsDriversInstalled = false
                        }
                    }
                } else if cfg.bootFromDiskOnly, !cfg.windowsDriversInstalled {
                    HVMUI.Button("驱动安装完成", variant: .primary, icon: "checkmark", size: .sm,
                                 disabled: !editable, probeID: "detail.boot.driversInstalled") {
                        store.saveConfig(vm) { $0.windowsDriversInstalled = true }
                    }
                }
            } else if cfg.installerISO != nil, !cfg.bootFromDiskOnly {
                // Linux: 装完 OS 切仅硬盘
                HVMUI.Button("安装完成", variant: .primary, icon: "checkmark", size: .sm,
                             disabled: !editable, probeID: "detail.boot.installed") {
                    store.saveConfig(vm) { $0.bootFromDiskOnly = true }
                }
            }
            Spacer()
        }
    }

    // MARK: - actions

    /// NSOpenPanel 选 ISO → installerISO=path + bootFromDiskOnly=false (重新进装机/启动盘态)
    private func selectISO() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.saveConfig(vm) { config in
            config.installerISO = url.path
            config.bootFromDiskOnly = false
        }
    }

    /// 弹出 ISO → installerISO=nil + bootFromDiskOnly=true (切仅硬盘启动)
    private func ejectISO() {
        store.saveConfig(vm) { config in
            config.installerISO = nil
            config.bootFromDiskOnly = true
        }
    }
}

