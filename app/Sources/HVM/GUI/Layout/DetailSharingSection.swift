// DetailSharingSection.swift — 详情页共享目录 section (host ↔ guest SPICE WebDAV).
//
// 仅 QEMU 后端 + Linux/Windows guest 生效, 否则灰显 + 文案. 改 sharedFolders 需停机
// (chardev 不支持热挂) → 仅 stopped 可增删/改 readOnly. 走 store.saveConfig 自动分流明文/加密.


import SwiftUI
import AppKit
import HVMControl
import HVMBundle

struct DetailSharingSection: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    private var cfg: VMConfig? { vm.config }
    /// WebDAV 共享: QEMU-only 后所有 VM (QEMU + Linux/Windows) 都支持
    private var supported: Bool { true }
    private var editable: Bool { supported && vm.runState == .stopped }

    var body: some View {
        if let cfg {
            HVMUI.Section("共享目录",
                          description: descText,
                          headerTrailing: {
                if supported {
                    HVMUI.Button("添加", variant: .primary, icon: "plus", size: .sm,
                                 disabled: !editable, probeID: "detail.sharing.add") {
                        addFolder()
                    }
                }
            }) {
                content(cfg)
            }
        }
    }

    private var descText: String? {
        if !supported { return "仅 QEMU 后端 + Linux/Windows guest 支持 (走 SPICE WebDAV)" }
        return vm.runState == .stopped ? "改动下次启动 VM 生效" : "停止 VM 后可增删"
    }

    @ViewBuilder
    private func content(_ cfg: VMConfig) -> some View {
        if !supported {
            Text("当前 VM (\(vm.engine.rawValue.uppercased()) / \(vm.guestOS.rawValue)) 不支持 WebDAV 共享目录.")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textTertiary)
        } else if cfg.sharedFolders.isEmpty {
            Text("无共享目录")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                ForEach(cfg.sharedFolders, id: \.name) { sf in
                    folderRow(sf)
                }
            }
        }
    }

    private func folderRow(_ sf: SharedFolderSpec) -> some View {
        HStack(spacing: HVMTheme.space.md) {
            HVMUI.Icon("folder", size: .sm, color: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HVMTheme.space.sm) {
                    Text(sf.name)
                        .font(HVMTheme.font.base)
                        .foregroundStyle(HVMTheme.color.textPrimary)
                    HVMUI.Badge(sf.readOnly ? "只读" : "读写",
                                variant: sf.readOnly ? .neutral : .warn, size: .sm)
                }
                Text(sf.hostPath)
                    .font(HVMTheme.font.monoSm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            // 读/写 切换 (停机可改; 走 saveConfig requireStopped)
            HVMUI.Toggle("可写", isOn: writableBinding(sf.name), size: .sm,
                         disabled: !editable,
                         probeID: "detail.sharing.writable-\(sf.name)")
            HVMUI.Button(icon: "trash", variant: .ghost, size: .sm,
                         disabled: !editable,
                         probeID: "detail.sharing.delete-\(sf.name)") {
                confirmDelete(sf)
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

    /// readOnly 取反的 binding: getter 读 live store.selected (按 name 命中, 非捕获渲染时 sf,
    /// 防 probe 闭包 stale); setter 走 saveConfig (停机生效).
    private func writableBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: {
                let ro = store.selected?.config?.sharedFolders
                    .first(where: { $0.name == name })?.readOnly ?? true
                return !ro
            },
            set: { writable in
                guard let cur = store.selected else { return }
                store.saveConfig(cur) { config in
                    if let idx = config.sharedFolders.firstIndex(where: { $0.name == name }) {
                        config.sharedFolders[idx].readOnly = !writable
                    }
                }
            }
        )
    }

    // MARK: - actions

    /// NSOpenPanel 选目录 → 弹 name 输入 (默认 basename sanitize) → 校验唯一 → saveConfig append
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let suggested = SharedFolderSpec.sanitizeName(url.lastPathComponent)
        let existing = Set(cfg?.sharedFolders.map(\.name) ?? [])
        Task { @MainActor in
            let r = await dialog.input(
                title: "添加共享目录 · \(url.lastPathComponent)",
                fields: [HVMUI.InputField(label: "共享名 (a-z 0-9 _ -)",
                                          placeholder: "code", initialText: suggested)],
                validate: { v in
                    let n = SharedFolderSpec.sanitizeName(v[0])
                    if v[0] != n { return .invalid("仅允许字母/数字/_/-, 最长 32") }
                    if existing.contains(n) { return .invalid("名称已存在") }
                    return .valid
                },
                confirmLabel: "添加",
                probeID: "detail.sharing.add.dlg"
            )
            guard case .submitted(let vals) = r else { return }
            let name = SharedFolderSpec.sanitizeName(vals[0])
            guard let cur = store.selected else { return }
            store.saveConfig(cur) { config in
                config.sharedFolders.append(
                    SharedFolderSpec(hostPath: url.path, name: name, readOnly: true))
            }
        }
    }

    /// 删除共享目录 — 破坏性, 二次确认 (CLAUDE.md 约束)
    private func confirmDelete(_ sf: SharedFolderSpec) {
        Task { @MainActor in
            let r = await dialog.confirm(
                title: "删除共享目录?",
                message: "共享 “\(sf.name)” (\(sf.hostPath)) 将被移除 (保存后下次启动生效). host 文件不受影响.",
                confirmLabel: "删除",
                destructive: true,
                probeID: "detail.sharing.delete.confirm-\(sf.name)"
            )
            guard case .confirmed = r, let cur = store.selected else { return }
            store.saveConfig(cur) { config in
                config.sharedFolders.removeAll { $0.name == sf.name }
            }
        }
    }
}

