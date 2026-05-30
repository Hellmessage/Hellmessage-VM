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
    // 网络 draft (V5). 跟 cpu/mem 统一 saveFooter 保存.
    @State private var draftNetworks: [NetworkSpec] = []
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
        VStack(alignment: .leading, spacing: 0) {
            // 固定头部 (标题 + badges + 启停/删除) — 不随下方卡片滚动
            headerBlock(vm)
                .padding(.horizontal, HVMTheme.space.xl)
                .padding(.top, HVMTheme.space.xl)
                .padding(.bottom, HVMTheme.space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 可滚动卡片区. 反向 zIndex (上→下递减) 让网络 section 的 Select 下拉浮在
            // 下方 saveFooter / 磁盘之上, 不被盖住.
            ScrollView {
                VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                    if vm.runState == .running {
                        runningNote.zIndex(55)
                    }
                    overviewSection(vm).zIndex(50)
                    if vm.config != nil {
                        resourceSection(vm).zIndex(40)
                        DetailNetworkSection(networks: $draftNetworks,
                                             editable: vm.runState == .stopped)
                            .zIndex(30)
                        diskSection(vm).zIndex(10)
                        DetailBootSection(vm: vm).zIndex(5)
                        DetailSharingSection(vm: vm).zIndex(4)
                        DetailOptionsSection(vm: vm).zIndex(3)
                    }
                }
                .padding(.horizontal, HVMTheme.space.xl)
                .padding(.bottom, HVMTheme.space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hvmHideScroller()   // 强制隐滚动条 (系统"始终显示"设置下 .scrollIndicators 不生效)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            HVMUI.Section("磁盘",
                          description: editable ? nil : "停止 VM 后可改",
                          headerTrailing: {
                HVMUI.Button("添加", variant: .primary, icon: "plus", size: .sm,
                             disabled: !editable, probeID: "detail.disk.add") {
                    if let cur = store.selected {
                        VMActions.addDisk(cur, store: store, dialog: dialog)
                    }
                }
            }) {
                VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                    ForEach(cfg.disks, id: \.path) { disk in
                        diskRow(disk: disk, editable: editable)
                    }
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
            HVMUI.Button("扩容", variant: .ghost, size: .sm, disabled: !editable,
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
            draftCPU = ""; draftMemGiB = ""; draftNetworks = []; return
        }
        draftCPU = "\(cfg.cpuCount)"
        draftMemGiB = "\(cfg.memoryMiB / 1024)"
        draftNetworks = cfg.networks
    }

    private func isDirty(_ vm: VMSummary) -> Bool {
        guard let cfg = vm.config else { return false }
        return draftCPU != "\(cfg.cpuCount)"
            || draftMemGiB != "\(cfg.memoryMiB / 1024)"
            || draftNetworks != cfg.networks
    }

    private var cpuValid: Bool { (Int(draftCPU) ?? 0) >= 1 }
    private var memValid: Bool { (Int(draftMemGiB) ?? 0) >= 1 }
    /// 所有 NIC 校验: MAC 格式 + bridged 模式需选接口
    private var networkValid: Bool {
        draftNetworks.allSatisfy { nic in
            NetworkSpec.isValidMAC(nic.macAddress)
                && (nic.mode != .vmnetBridged || !(nic.bridgedInterface ?? "").isEmpty)
        }
    }

    @ViewBuilder
    private func resourceSection(_ vm: VMSummary) -> some View {
        let editable = vm.runState == .stopped
        // 放弃/保存 放在"资源"标题右侧 (跟磁盘添加同款 headerTrailing), dirty 才显示.
        // 表单字段 (cpu/mem/network) 统一这一组按钮保存.
        HVMUI.Section("资源",
                      description: editable ? nil : "停止 VM 后可编辑",
                      headerTrailing: {
            if isDirty(vm) {
                HStack(spacing: HVMTheme.space.sm) {
                    HVMUI.Button("放弃", variant: .secondary, size: .sm,
                                 probeID: "detail.button.discard") { resetDraft() }
                    HVMUI.Button("保存", variant: .primary, icon: "checkmark", size: .sm,
                                 disabled: !(cpuValid && memValid && networkValid),
                                 probeID: "detail.button.save") { saveForm(vm) }
                }
            }
        }) {
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

    /// 表单保存 (cpu/mem/network 一起写)
    private func saveForm(_ vm: VMSummary) {
        guard let cpu = Int(draftCPU), let mem = UInt64(draftMemGiB) else { return }
        let nets = draftNetworks
        store.saveConfig(vm) { config in
            config.cpuCount = cpu
            config.memoryMiB = mem * 1024
            config.networks = nets
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
                    if let cur = store.selected {
                        VMActions.confirmKill(cur, store: store, dialog: dialog)
                    }
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
