// EditConfigDialog.swift
// stopped 视图里点 cpu / memory 卡片弹出的编辑面板. 套 HVMModal.
// 必须 VM stopped (BundleLock.isBusy 检测; 等价 hvm-cli config set).
//
// 网络管理已不在此弹窗 (走状态栏 vmnet popup + 详情页 NIC 卡片). 本弹窗专注
// 资源 + 剪贴板 + 共享文件 (SPICE WebDAV).

import AppKit
import SwiftUI
import HVMBundle
import HVMCore

struct EditConfigDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let item: AppModel.VMListItem

    @State private var cpuText: String
    @State private var memGiBText: String
    /// 整张 VMConfig 的 draft, VMSettingsNetworkSection 直接绑定 networks 段.
    @State private var draft: VMConfig

    init(model: AppModel, errors: ErrorPresenter, item: AppModel.VMListItem) {
        // 调用方 (DialogOverlay) 已保证 config != nil (加密 VM 不进此 dialog)
        guard let cfg = item.config else {
            preconditionFailure("EditConfigDialog 不支持加密 VM (config nil)")
        }
        self._model = Bindable(model)
        self._errors = Bindable(errors)
        self.item = item
        self._cpuText = State(initialValue: String(cfg.cpuCount))
        self._memGiBText = State(initialValue: String(cfg.memoryMiB / 1024))
        self._draft = State(initialValue: cfg)
    }

    /// VM 是否运行中 — running 期允许打开本 dialog 查看配置, 但保存按钮 disable.
    private var isRunning: Bool {
        BundleLock.isBusy(bundleURL: item.bundleURL)
    }

    var body: some View {
        HVMModal(
            title: isRunning ? "查看配置" : "Edit Configuration",
            icon: .info,
            width: 560,
            closeAction: { close() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HVMSpace.lg) {
                    if isRunning {
                        Text("VM 运行中 — 字段仅查看, 修改需先停止 VM. (剪贴板共享在详情顶栏可即时切换)")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.statusPaused)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("修改 \(item.displayName) 的资源配置. 必须 VM 停止. Engine (\(item.config?.engine.rawValue ?? "—")) 不可改.")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: HVMSpace.md) {
                        VStack(alignment: .leading, spacing: HVMSpace.xs) {
                            LabelText("CPU")
                            HVMTextField("4", text: $cpuText, suffix: "cores")
                        }
                        VStack(alignment: .leading, spacing: HVMSpace.xs) {
                            LabelText("Memory")
                            HVMTextField("8", text: $memGiBText, suffix: "GB")
                        }
                    }

                    // 剪贴板共享 — 仅 QEMU 后端 (VZ macOS guest 自带剪贴板)
                    if item.config?.engine == .qemu {
                        HVMToggle(
                            "剪贴板共享",
                            isOn: $draft.clipboardSharingEnabled,
                            help: "host ↔ guest UTF-8 文本双向同步, 走 vdagent virtio-serial. 运行中也可在详情顶栏即时切换"
                        )
                        HVMToggle(
                            "macOS 风格快捷键",
                            isOn: $draft.macStyleShortcuts,
                            help: "把 host cmd 当 guest ctrl 转发 (cmd+c → ctrl+c 等). 关闭后回到 cmd → Win 键. 关闭并重开 VM 详情或独立窗口生效"
                        )
                    }

                    // 共享文件配置 (SPICE WebDAV). 仅 QEMU 后端可加 — VZ 推后.
                    if item.config?.engine == .qemu {
                        sharedFolderSection
                    }

                    // vmnet daemon 安装/重启/卸载面板 — 保留 daemon 管理入口,
                    // 但本弹窗不再露 NIC 卡片 (NIC 管理走详情页 + 状态栏 vmnet popup).
                    VmnetDaemonCard(networks: $draft.networks)
                }
                .padding(.vertical, HVMSpace.xs)
            }
            .frame(maxHeight: 560)
            // VM 运行中: 整个表单 disabled (字段灰显, 用户能看不能改)
            .disabled(isRunning)
        } footer: {
            HVMModalFooter {
                Button(isRunning ? "关闭" : "取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                if !isRunning {
                    Button("保存") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }

    private func close() {
        model.editConfigItem = nil
    }

    private func save() {
        do {
            guard let cpuInt = Int(cpuText), cpuInt >= 1 else {
                throw HVMError.config(.missingField(name: "cpu 必须 >=1"))
            }
            guard let memGiB = UInt64(memGiBText), memGiB >= 1 else {
                throw HVMError.config(.missingField(name: "memory 必须 >=1 GiB"))
            }
            // 校验每张 NIC: vmnetBridged 必须有接口
            for (idx, net) in draft.networks.enumerated() where net.enabled {
                if net.mode == .vmnetBridged,
                   (net.bridgedInterface ?? "").isEmpty {
                    throw HVMError.config(.missingField(name: "networks[\(idx)] bridged 接口未选"))
                }
                if !NetworkSpec.isValidMAC(net.macAddress) {
                    throw HVMError.config(.missingField(name: "networks[\(idx)] MAC 格式非法 (\(net.macAddress))"))
                }
            }
            // 走 saveConfig 走加密分流 (加密 VM 重密 .yaml.enc; 明文 VM BundleIO.save).
            // BundleLock isBusy 校验已封装在 saveConfig 内 (requireStopped 默认 true)
            try model.saveConfig(item: item) { config in
                config.cpuCount = cpuInt
                config.memoryMiB = memGiB * 1024
                // 网络仍随源 config 不动 (本弹窗不再管 networks)
                config.clipboardSharingEnabled = draft.clipboardSharingEnabled
                config.macStyleShortcuts = draft.macStyleShortcuts
                config.sharedFolders = draft.sharedFolders
            }
            close()
        } catch {
            errors.present(error)
        }
    }

    // MARK: - 共享文件 (SPICE WebDAV) 子区

    private var sharedFolderSection: some View {
        VStack(alignment: .leading, spacing: HVMSpace.sm) {
            HStack {
                Text("共享文件 (SPICE WebDAV)").font(HVMFont.bodyBold)
                Spacer()
            }
            if draft.sharedFolders.isEmpty {
                Text("(无 — 点下面按钮添加 host 目录, 启动 VM 后 guest 内自动可见)")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            } else {
                ForEach(draft.sharedFolders.indices, id: \.self) { idx in
                    sharedFolderRow(idx: idx)
                }
            }
            HStack {
                Button("+ 添加共享目录…") { presentAddSharedFolder() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
            }
            Text("Win guest: \\\\localhost\\dav\\<name>; Linux: GVFS davs://localhost/<name>. 改动重启 VM 生效.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
    }

    @ViewBuilder
    private func sharedFolderRow(idx: Int) -> some View {
        let sf = draft.sharedFolders[idx]
        HStack(spacing: HVMSpace.sm) {
            Text(sf.name)
                .font(HVMFont.body)
                .lineLimit(1)
            // 切换 ro/rw — 直接改 draft, [保存] 才落盘 (与 cpu/mem 一致)
            Button(sf.readOnly ? "[只读]" : "[可写]") {
                draft.sharedFolders[idx].readOnly.toggle()
            }
            .buttonStyle(.plain)
            .font(HVMFont.small)
            .foregroundStyle(sf.readOnly ? HVMColor.textSecondary : HVMColor.accent)
            .help("点击切换 只读 ↔ 可写 (保存后生效)")

            Text(sf.hostPath)
                .font(HVMFont.monoSmall)
                .foregroundStyle(HVMColor.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                draft.sharedFolders.remove(at: idx)
            } label: {
                Image(systemName: "trash").font(HVMFont.small)
            }
            .buttonStyle(IconButtonStyle())
            .help("移除")
        }
    }

    /// NSOpenPanel 选目录 → 自动按 basename 派生 name → append 到 draft (默认 ro).
    /// 重名时追加 -2 / -3. 仅修内存 draft, [保存] 后落盘.
    private func presentAddSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择 host 共享目录"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = SharedFolderSpec.sanitizeName(url.lastPathComponent)
        var name = base
        var suffix = 2
        let existing = Set(draft.sharedFolders.map { $0.name })
        while existing.contains(name) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        draft.sharedFolders.append(
            SharedFolderSpec(hostPath: url.path, name: name, readOnly: true)
        )
    }
}
