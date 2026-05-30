// DetailOverviewView.swift — 右栏 VM 详情 (只读 overview + 启停; M5).
//
// 本稿只做只读概览 + 启停按钮. 完整配置编辑 (network/disk/sharing/加密) 留
// NEW_GUI_VM_DETAIL.md 子稿. 运行中不嵌真画面 (标占位, framebuffer 子稿补).
// 加密 VM 解锁前 config=nil, overview 兜底只显基础信息.

#if NEW_GUI

import SwiftUI
import HVMControl
import HVMBundle

struct DetailOverviewView: View {
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    // 资源 section 编辑 draft (字符串, 校验时转 Int). 切换 VM 时 reset.
    @State private var draftCPU = ""
    @State private var draftMemGiB = ""
    // 已加载 draft 的 VM id + 当时 config 是否存在 — 防 1Hz 刷新误清未保存编辑;
    // 但解锁后 config 由 nil → 非 nil 时要重新 sync (id 没变, 靠 hasConfig 触发).
    @State private var draftLoadedID: UUID? = nil
    @State private var draftLoadedHasConfig = false

    var body: some View {
        ZStack {
            HVMTheme.color.bgBase
            if let vm = store.selected {
                detail(vm)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: HVMTheme.space.md) {
            HVMUI.Icon("rectangle.on.rectangle.angled", size: .xl, color: .secondary)
            Text("选择左侧虚拟机查看详情")
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textTertiary)
        }
    }

    private func detail(_ vm: VMSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                headerBlock(vm)
                if vm.runState == .running {
                    runningNote
                }
                overviewSection(vm)
                if vm.config != nil {
                    resourceSection(vm)
                    if isDirty(vm) {
                        saveFooter(vm)
                    }
                    diskSection(vm)
                }
            }
            .padding(HVMTheme.space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 选中 VM 变化 / 解锁后 config 出现时同步 draft; 1Hz 刷新不清 (靠守卫)
        .onChange(of: store.selectedID) { _, _ in syncDraftIfNeeded() }
        .onChange(of: store.selected?.config?.cpuCount) { _, _ in syncDraftIfNeeded() }
        .onAppear { syncDraftIfNeeded() }
    }

    // MARK: - 磁盘 (V4)

    @ViewBuilder
    private func diskSection(_ vm: VMSummary) -> some View {
        if let cfg = vm.config {
            let editable = vm.runState == .stopped
            HVMUI.Section("磁盘", description: editable ? nil : "停止 VM 后可改") {
                VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                    ForEach(cfg.disks, id: \.path) { disk in
                        diskRow(disk: disk, editable: editable)
                    }
                    HVMUI.Button("添加数据盘…", variant: .secondary, icon: "plus",
                                 disabled: !editable, probeID: "detail.disk.add") {
                        if let cur = store.selected {
                            VMActions.addDisk(cur, store: store, dialog: dialog)
                        }
                    }
                    .padding(.top, HVMTheme.space.xs)
                }
            }
        }
    }

    private func diskRow(disk: DiskSpec, editable: Bool) -> some View {
        HStack(spacing: HVMTheme.space.md) {
            HVMUI.Icon(disk.role == .main ? "internaldrive" : "externaldrive",
                       size: .sm, color: .secondary)
            Text(disk.role == .main ? "主盘" : "数据盘")
                .font(HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text("\(disk.sizeGiB) GiB · \(disk.format.rawValue)")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
            Spacer()
            HVMUI.Button("扩容…", variant: .ghost, size: .sm, disabled: !editable,
                         probeID: "detail.disk.resize-\(disk.path)") {
                if let cur = store.selected {
                    VMActions.resizeDisk(cur, disk: disk, store: store, dialog: dialog)
                }
            }
            if disk.role == .data {
                HVMUI.Button("删除", variant: .ghost, size: .sm, disabled: !editable,
                             probeID: "detail.disk.delete-\(disk.path)") {
                    if let cur = store.selected {
                        VMActions.confirmDeleteDisk(cur, disk: disk, store: store, dialog: dialog)
                    }
                }
            }
        }
    }

    // MARK: - 资源编辑 (V3)

    /// 选中 VM 真变化 / config 由无到有 (解锁) 才 reset draft; 守卫防 1Hz 刷新误清未保存编辑
    private func syncDraftIfNeeded() {
        let curID = store.selectedID
        let hasConfig = store.selected?.config != nil
        guard draftLoadedID != curID || draftLoadedHasConfig != hasConfig else { return }
        draftLoadedID = curID
        draftLoadedHasConfig = hasConfig
        resetDraft()
    }

    private func resetDraft() {
        guard let cfg = store.selected?.config else {
            draftCPU = ""; draftMemGiB = ""; return
        }
        draftCPU = "\(cfg.cpuCount)"
        draftMemGiB = "\(cfg.memoryMiB / 1024)"
    }

    private func isDirty(_ vm: VMSummary) -> Bool {
        guard let cfg = vm.config else { return false }
        return draftCPU != "\(cfg.cpuCount)" || draftMemGiB != "\(cfg.memoryMiB / 1024)"
    }

    private var cpuValid: Bool { (Int(draftCPU) ?? 0) >= 1 }
    private var memValid: Bool { (Int(draftMemGiB) ?? 0) >= 1 }

    @ViewBuilder
    private func resourceSection(_ vm: VMSummary) -> some View {
        let editable = vm.runState == .stopped
        HVMUI.Section("资源", description: editable ? nil : "停止 VM 后可编辑") {
            HStack(alignment: .top, spacing: HVMTheme.space.lg) {
                HVMUI.TextField("CPU", text: $draftCPU, placeholder: "4",
                                suffix: "核",
                                errorMessage: (editable && !cpuValid) ? "至少 1 核" : nil,
                                disabled: !editable,
                                probeID: "detail.field.cpu")
                    .frame(maxWidth: 160)
                HVMUI.TextField("内存", text: $draftMemGiB, placeholder: "4",
                                suffix: "GiB",
                                errorMessage: (editable && !memValid) ? "至少 1 GiB" : nil,
                                disabled: !editable,
                                probeID: "detail.field.memory")
                    .frame(maxWidth: 160)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func saveFooter(_ vm: VMSummary) -> some View {
        HStack(spacing: HVMTheme.space.sm) {
            Spacer()
            HVMUI.Button("放弃", variant: .secondary,
                         probeID: "detail.button.discard") {
                resetDraft()
            }
            HVMUI.Button("保存", variant: .primary, icon: "checkmark",
                         disabled: !(cpuValid && memValid),
                         probeID: "detail.button.save") {
                guard let cpu = Int(draftCPU), let mem = UInt64(draftMemGiB) else { return }
                store.saveConfig(vm) { config in
                    config.cpuCount = cpu
                    config.memoryMiB = mem * 1024
                }
            }
        }
    }

    private func headerBlock(_ vm: VMSummary) -> some View {
        HStack(alignment: .center, spacing: HVMTheme.space.lg) {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                Text(vm.displayName)
                    .font(HVMTheme.font.xl)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                HStack(spacing: HVMTheme.space.sm) {
                    HVMUI.Badge(vm.guestOS.badgeLabel, variant: vm.guestOS.badgeVariant, size: .sm)
                    if vm.isEncrypted {
                        HVMUI.Badge("Encrypted", variant: .accent, icon: "lock.fill", size: .sm)
                    }
                    HVMUI.Badge(vm.runState.badgeLabel, variant: vm.runState.badgeVariant, size: .sm)
                }
            }
            Spacer()
            actionButtons(vm)
        }
    }

    private var runningNote: some View {
        HStack(spacing: HVMTheme.space.sm) {
            HVMUI.Icon("display", size: .sm, color: .info)
            Text("运行中 — 画面嵌入待 framebuffer 子稿 (当前可用老 GUI 看画面)")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
        }
        .padding(HVMTheme.space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                .fill(HVMTheme.color.bgRaised)
        )
    }

    @ViewBuilder
    private func overviewSection(_ vm: VMSummary) -> some View {
        HVMUI.Section("概览") {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                infoRow("ID", vm.id.uuidString, mono: true)
                infoRow("引擎", vm.engine.rawValue.uppercased())
                if let cfg = vm.config {
                    infoRow("CPU", "\(cfg.cpuCount) 核")
                    infoRow("内存", "\(cfg.memoryMiB / 1024) GiB")
                    if let disk = cfg.disks.first {
                        infoRow("主盘", "\(disk.sizeGiB) GiB · \(disk.format.rawValue)")
                    }
                } else {
                    // 加密 VM 未解锁: config 为 nil
                    infoRow("加密", "🔒 已加密 — 解锁查看完整配置 (后续子稿)")
                }
            }
        }
    }

    /// 操作按钮组 — 放在标题右侧 (header trailing). 按 vm.runState 决定显示哪些; 但动作
    /// 一律读 store.selected 再执行, 防 hvm-dbg gui probe 闭包 stale 作用到旧 vm
    /// (probe onAppear 只注册一次, view 复用不重注册; 真人点击无此问题, 自动化会撞).
    @ViewBuilder
    private func actionButtons(_ vm: VMSummary) -> some View {
        HStack(spacing: HVMTheme.space.sm) {
            if vm.runState == .running {
                HVMUI.Button("停止", variant: .secondary, icon: "stop.circle",
                             probeID: "detail.button.stop") {
                    if let cur = store.selected { store.stop(cur) }
                }
                HVMUI.Button("强制停止", variant: .destructive, icon: "bolt.slash",
                             probeID: "detail.button.kill") {
                    if let cur = store.selected { store.kill(cur) }
                }
            } else if vm.isEncrypted && !store.isUnlocked(vm.id) {
                // 加密未解锁: 解锁 (+ 删除不需密钥)
                HVMUI.Button("解锁", variant: .primary, icon: "lock.open",
                             isLoading: store.isUnlocking(vm.id),
                             probeID: "detail.button.unlock") {
                    if let cur = store.selected {
                        VMActions.unlock(cur, store: store, dialog: dialog)
                    }
                }
                HVMUI.Button("删除", variant: .destructive, icon: "trash",
                             probeID: "detail.button.delete") {
                    if let cur = store.selected {
                        VMActions.confirmDelete(cur, store: store, dialog: dialog)
                    }
                }
            } else {
                HVMUI.Button("启动", variant: .primary, icon: "play.fill",
                             probeID: "detail.button.start") {
                    if let cur = store.selected {
                        VMActions.start(cur, store: store, dialog: dialog)
                    }
                }
                HVMUI.Button("删除", variant: .destructive, icon: "trash",
                             probeID: "detail.button.delete") {
                    if let cur = store.selected {
                        VMActions.confirmDelete(cur, store: store, dialog: dialog)
                    }
                }
            }
            // 已解锁加密 VM: 锁定按钮 (任何 runState)
            if vm.isEncrypted && store.isUnlocked(vm.id) {
                HVMUI.Button("锁定", variant: .secondary, icon: "lock",
                             probeID: "detail.button.lock") {
                    store.lock(vm.id)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: HVMTheme.space.md) {
            Text(label)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(mono ? HVMTheme.font.monoSm : HVMTheme.font.base)
                .foregroundStyle(HVMTheme.color.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

#endif
