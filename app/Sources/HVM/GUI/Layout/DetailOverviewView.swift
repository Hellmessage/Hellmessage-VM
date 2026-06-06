// DetailOverviewView.swift — 右栏 VM 详情 (概览 + 启停 + inline 配置编辑 + running framebuffer TAB).
//
// running 详情区分「画面」/「配置」TAB. 加密 VM 解锁前 config=nil, overview 兜底只显基础信息.


import SwiftUI
import AppKit
import HVMControl
import HVMBundle

struct DetailOverviewView: View {
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    // 资源 section 编辑 draft (字符串, 校验时转 Int). 切换 VM 时 reset.
    @State private var draftCPU = ""
    @State private var draftMemGiB = ""
    // 网络 draft, 跟 cpu/mem 统一 saveFooter 保存.
    @State private var draftNetworks: [NetworkSpec] = []
    // 已加载 draft 的 VM id + 当时 config 是否存在 — 防 1Hz 刷新误清未保存编辑;
    // 解锁后 config 由 nil → 非 nil 时 (id 没变) 靠 hasConfig 触发重新 sync.
    @State private var draftLoadedID: UUID? = nil
    @State private var draftLoadedHasConfig = false

    /// running 详情区: 画面 / 配置 切换. 切 VM / 改 runState 时 reset 回 .screen.
    enum RunningTab { case screen, config }
    @State private var runningTab: RunningTab = .screen

    /// running 画面态: NAV (头部 + tab 栏) 是否折叠 — 折叠后 framebuffer 占满, 给画面腾空间.
    /// 顶部居中的小图标切换; 切 VM / 改 runState 时 reset 回展开.
    @State private var navCollapsed = false

    /// NAV 分辨率 inline 编辑器 draft — 宽/高字段. onAppear / VM 切换 / 实时分辨率变化时同步 guest 真实值.
    @State private var draftResolutionW: String = ""
    @State private var draftResolutionH: String = ""

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
        let isRunning = vm.runState == .running
        // 仅 running 画面态可折叠 NAV; 折叠生效条件 = 画面态 + navCollapsed.
        let screenMode = isRunning && runningTab == .screen
        let showNav = !(screenMode && navCollapsed)
        return ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                // 固定头部 (标题 + badges + 启停/删除) — 不随下方卡片滚动
                if showNav {
                    headerBlock(vm)
                        .padding(.horizontal, HVMTheme.space.xl)
                        .padding(.top, HVMTheme.space.xl)
                        .padding(.bottom, isRunning ? HVMTheme.space.md : HVMTheme.space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // running: 画面 / 配置 TAB 切换
                    if isRunning {
                        runningTabBar(vm)
                            .padding(.horizontal, HVMTheme.space.xl)
                            .padding(.bottom, HVMTheme.space.md)
                    }
                }

                // running 画面 tab → framebuffer; 其它 → 配置滚动
                if screenMode {
                    QemuFramebufferView(vm: vm, store: store,
                                        dialogPresenting: dialog.isPresenting)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 切 VM 必须重建 NSView: makeNSView 只跑一次 (内含 ensureQemuFanout + addSubscriber),
                        // 不绑 id 则切 VM 只走 updateNSView, fbView 仍订阅旧 VM fanout → 画面不切换.
                        .id(vm.id)
                } else {
                    configScroll(vm)
                }
            }

            // running 画面态: 顶部居中的 NAV 折叠/展开切换图标 (overlay, 折叠后仍可点回)
            if screenMode {
                navToggle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: store.selectedID) { _, _ in
            syncDraftIfNeeded(); runningTab = .screen; navCollapsed = false
            if let cur = store.selected { store.refreshGuestIP(cur) }
        }
        .onChange(of: store.selected?.config?.cpuCount) { _, _ in syncDraftIfNeeded() }
        .onChange(of: store.selected?.runState) { _, _ in
            runningTab = .screen; navCollapsed = false
            if let cur = store.selected { store.refreshGuestIP(cur) }   // 起/停切换时刷 guest IP
        }
        .onAppear {
            syncDraftIfNeeded()
            if let cur = store.selected { store.refreshGuestIP(cur) }
        }
    }

    /// 画面 / 配置 TAB (running). 右侧 inline 编辑器: 宽/高输入框 + 设置按钮, 跟拖窗口同款通路改 guest 分辨率.
    private func runningTabBar(_ vm: VMSummary) -> some View {
        HStack(spacing: HVMTheme.space.sm) {
            HVMUI.Button("画面", variant: runningTab == .screen ? .primary : .ghost, size: .sm,
                         probeID: "detail.tab.screen") { runningTab = .screen }
            HVMUI.Button("配置", variant: runningTab == .config ? .primary : .ghost, size: .sm,
                         probeID: "detail.tab.config") { runningTab = .config }
            Spacer()
            resolutionEditor(vm)
        }
    }

    // MARK: - 分辨率 inline 编辑器 (NAV 右侧, running 时显)

    /// 输入硬上限 (跟 hvm-dbg display-resize 对齐, 见 DisplayResizeCommand.swift:35).
    private static let resolutionMinW: UInt32 = 640
    private static let resolutionMaxW: UInt32 = 7680
    private static let resolutionMinH: UInt32 = 480
    private static let resolutionMaxH: UInt32 = 4320

    /// 两输入框 (宽 × 高) + 设置按钮. 走 SwiftUI 控件不依赖 popover, 不撞 Metal CAMetalLayer z-order.
    /// onAppear / VM 切换 / 实时分辨率变化时同步 draft 到当前 guest 真实值; 范围外按钮 disabled.
    private func resolutionEditor(_ vm: VMSummary) -> some View {
        HStack(spacing: HVMTheme.space.xs) {
            HVMUI.TextField(text: $draftResolutionW,
                            placeholder: "宽",
                            size: .sm,
                            probeID: "detail.nav.resolution.width")
                .frame(width: 70)
            SwiftUI.Text("×")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
            HVMUI.TextField(text: $draftResolutionH,
                            placeholder: "高",
                            size: .sm,
                            probeID: "detail.nav.resolution.height")
                .frame(width: 70)
            HVMUI.Button("设置",
                         variant: .primary, size: .sm,
                         disabled: !isResolutionDraftValid,
                         probeID: "detail.nav.resolution.apply") {
                // probe 闭包在 onAppear 一次注册不重注册, 捕获渲染时 vm 会 stale (用户切 VM 后 hvm-dbg gui
                // click apply 仍命中旧 VM); 读 store.selected 让动作命中当前选中. CLAUDE.md 约束.
                guard let w = UInt32(draftResolutionW),
                      let h = UInt32(draftResolutionH),
                      let cur = store.selected else { return }
                store.requestResize(cur, width: w, height: h)
            }
        }
        .onAppear { syncResolutionDraft(vm) }
        .onChange(of: vm.id) { _, _ in syncResolutionDraft(vm) }
        .onChange(of: store.currentResolution(for: vm)) { _, _ in
            syncResolutionDraft(vm)
        }
    }

    /// draft 校验: 都是正整数, 都在 640..7680 × 480..4320 内. 失败时设置按钮 disabled (probe 也跳过注册).
    private var isResolutionDraftValid: Bool {
        guard let w = UInt32(draftResolutionW),
              let h = UInt32(draftResolutionH) else { return false }
        return w >= Self.resolutionMinW && w <= Self.resolutionMaxW
            && h >= Self.resolutionMinH && h <= Self.resolutionMaxH
    }

    /// 把 draft 同步到 guest 真实分辨率. nil (还没收到首帧 SurfaceNew) 时填默认 1920×1080.
    private func syncResolutionDraft(_ vm: VMSummary) {
        if let r = store.currentResolution(for: vm) {
            draftResolutionW = String(r.width)
            draftResolutionH = String(r.height)
        } else if draftResolutionW.isEmpty {
            draftResolutionW = "1920"
            draftResolutionH = "1080"
        }
    }

    /// running 画面态顶部居中的小图标: 切换 NAV (头部 + tab 栏) 折叠/展开.
    /// 折叠时显示向下箭头 (点击展开), 展开时显示向上箭头 (点击折叠收起腾画面).
    private var navToggle: some View {
        HVMUI.Button(icon: navCollapsed ? "chevron.down" : "chevron.up",
                     variant: .icon, size: .sm,
                     probeID: "detail.button.navToggle",
                     probeLabel: navCollapsed ? "展开导航栏" : "折叠导航栏") {
            navCollapsed.toggle()
        }
        .background(HVMTheme.color.bgRaised.opacity(0.85), in: Capsule())
        .padding(.top, navCollapsed ? HVMTheme.space.xs : HVMTheme.space.sm)
    }

    /// 配置滚动区 (stopped 全可编辑 / running 多字段 disabled).
    private func configScroll(_ vm: VMSummary) -> some View {
            // 反向 zIndex (上→下递减) 让网络 section 的 Select 下拉浮在下方 section 之上
            ScrollView {
                VStack(alignment: .leading, spacing: HVMTheme.space.xl) {
                    if vm.runState == .running {
                        runningNote.zIndex(60)
                    }
                    overviewSection(vm).zIndex(55)
                    // 共享目录 / 选项 / 加密 放在资源上面 (用户偏好)
                    if vm.config != nil {
                        DetailSharingSection(vm: vm).zIndex(50)
                        DetailOptionsSection(vm: vm).zIndex(45)
                    }
                    // 加密 section 入口不依赖 config (锁定态 config=nil 也要显解密/改密入口)
                    DetailEncryptionSection(vm: vm).zIndex(40)
                    if vm.config != nil {
                        resourceSection(vm).zIndex(35)
                        DetailNetworkSection(networks: $draftNetworks,
                                             editable: vm.runState == .stopped)
                            .zIndex(30)
                        diskSection(vm).zIndex(10)
                        DetailBootSection(vm: vm).zIndex(5)
                        DetailSnapshotSection(vm: vm).zIndex(4)
                    }
                }
                .padding(.horizontal, HVMTheme.space.xl)
                .padding(.bottom, HVMTheme.space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hvmHideScroller()   // 强制隐滚动条 (系统"始终显示"下 .scrollIndicators 不生效)
            }
            .scrollIndicators(.hidden)
    }

    // MARK: - 磁盘

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

    // MARK: - 资源编辑

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
        // 放弃/保存 放标题右侧 headerTrailing, dirty 才显示; cpu/mem/network 统一这组按钮保存.
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
                    // 网络模式徽标 (NAT / 桥接 / Host / 共享); 多 NIC 去重展示, 加密未解锁 config=nil 时不显
                    ForEach(networkModeBadges(vm), id: \.self) { mode in
                        HVMUI.Badge(mode.badgeLabel, variant: mode.badgeVariant, icon: mode.badgeIcon, size: .sm)
                    }
                }
            }
            Spacer()
            actionButtons(vm)
        }
    }

    /// 头部网络模式徽标取值: 取已启用网卡的模式去重 (保序). 加密未解锁 (config=nil) 返空不显.
    private func networkModeBadges(_ vm: VMSummary) -> [NetworkMode] {
        guard let nets = vm.config?.networks else { return [] }
        var seen: Set<NetworkMode> = []
        var modes: [NetworkMode] = []
        for nic in nets where nic.enabled {
            if seen.insert(nic.mode).inserted { modes.append(nic.mode) }
        }
        return modes
    }

    private var runningNote: some View {
        HStack(spacing: HVMTheme.space.sm) {
            HVMUI.Icon("display", size: .sm, color: .info)
            Text("运行中 — 切到「画面」tab 看 VM 屏幕 + 键鼠操作; 运行中多数配置需停机才能改")
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
                    infoRow("加密", "🔒 已加密 — 解锁查看完整配置")
                }
                if vm.runState == .running {
                    guestIPRow(vm)
                }
            }
        }
    }

    /// guest IP 行 (running 才显). 走 store.guestIPs 缓存 (IPC guest.netinfo → qemu-ga). 带复制按钮.
    @ViewBuilder
    private func guestIPRow(_ vm: VMSummary) -> some View {
        HStack(alignment: .top, spacing: HVMTheme.space.md) {
            Text("guest IP")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)
                .frame(width: 64, alignment: .leading)
            if let ip = store.guestIPs[vm.id] {
                Text(ip)
                    .font(HVMTheme.font.monoSm)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                    .textSelection(.enabled)
                HVMUI.Button(icon: "doc.on.doc", variant: .icon, size: .sm,
                             probeID: "detail.guestIP.copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(ip, forType: .string)
                }
            } else {
                Text("获取中…（需 guest 装 qemu-ga）")
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 操作按钮组 (header trailing). 按 vm.runState 决定显示哪些; 动作一律读 store.selected
    /// 再执行, 防 probe 闭包 stale 作用到旧 vm (probe onAppear 只注册一次, 自动化会撞).
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
            // 克隆 (仅 stopped; 加密源在 dialog 内收密码). 动作读 store.selected 防 stale.
            if vm.runState == .stopped {
                HVMUI.Button("克隆", variant: .secondary, icon: "doc.on.doc",
                             probeID: "detail.button.clone") {
                    if let cur = store.selected { presentClone(cur) }
                }
            }
        }
    }

    /// present 克隆 dialog (读 store.selected 防 stale; store 显式传, dialog overlay 拿不到环境).
    private func presentClone(_ vm: VMSummary) {
        let s = store
        dialog.present { handle in
            CloneVMDialog(vm: vm, handle: handle, store: s)
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

