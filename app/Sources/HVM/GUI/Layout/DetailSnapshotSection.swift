// DetailSnapshotSection.swift — 详情页快照 section (APFS clonefile, 见 SnapshotManager / VMControl+Snapshot).
//
// 创建/恢复必须 stopped (盘在写则快照不一致). 恢复 + 删除是破坏性操作, 走 dialog.confirm(destructive:true).
// 快照含 disks + config + nvram + tpm (整 VM 状态, 不含运行态 RAM — HVF 无含 RAM 快照).
// 动作读 store.selected 防 stale; 列表走 @State + 操作后 reload.


import SwiftUI
import HVMControl
import HVMBundle
import HVMStorage

struct DetailSnapshotSection: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter
    @State private var snaps: [SnapshotManager.Info] = []

    /// 创建/恢复要求停机; 删除安全 (只删 snapshots/<name>/, 不动当前 VM) 故不受此限.
    private var editable: Bool { vm.runState == .stopped }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HVMUI.Section("快照",
                      description: editable
                        ? "APFS clonefile · 含磁盘/配置/NVRAM/TPM · 秒级近零空间 (不含运行态)"
                        : "停止 VM 后可创建 / 恢复",
                      headerTrailing: {
            HVMUI.Button("创建快照", variant: .primary, icon: "camera", size: .sm,
                         disabled: !editable, probeID: "detail.snapshot.create") {
                createSnapshot()
            }
        }) {
            content
        }
        .onAppear { reload() }
        .onChange(of: vm.id) { _, _ in reload() }
        .onChange(of: vm.runState) { _, _ in reload() }
    }

    @ViewBuilder
    private var content: some View {
        if snaps.isEmpty {
            Text("无快照")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                ForEach(snaps, id: \.name) { snapRow($0) }
            }
        }
    }

    private func snapRow(_ s: SnapshotManager.Info) -> some View {
        HStack(spacing: HVMTheme.space.md) {
            HVMUI.Icon("camera", size: .sm, color: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textPrimary)
                Text(Self.dateFmt.string(from: s.createdAt))
                    .font(HVMTheme.font.monoSm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
            }
            Spacer()
            HVMUI.Button("恢复", variant: .secondary, size: .sm,
                         disabled: !editable,
                         probeID: "detail.snapshot.restore-\(s.name)") {
                confirmRestore(s)
            }
            HVMUI.Button(icon: "trash", variant: .ghost, size: .sm,
                         probeID: "detail.snapshot.delete-\(s.name)") {
                confirmDelete(s)
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

    // MARK: - actions (读 store.selected 防 stale probe 闭包)

    private func reload() {
        snaps = store.snapshots(store.selected ?? vm)
    }

    /// 创建: 输入名 (校验 charset + 唯一) → store.createSnapshot → reload.
    private func createSnapshot() {
        let existing = Set(snaps.map(\.name))
        let suggested = "snap-\(snaps.count + 1)"
        Task { @MainActor in
            let r = await dialog.input(
                title: "创建快照",
                fields: [HVMUI.InputField(label: "快照名 (字母/数字/-/_/.)",
                                          placeholder: "snap-1", initialText: suggested)],
                validate: { v in
                    let n = v[0]
                    if n.isEmpty || n.count > 64 { return .invalid("1-64 字符") }
                    let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
                    if !n.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                        return .invalid("仅允许字母/数字/-/_/.")
                    }
                    if existing.contains(n) { return .invalid("名称已存在") }
                    return .valid
                },
                confirmLabel: "创建",
                probeID: "detail.snapshot.create.dlg"
            )
            guard case .submitted(let vals) = r, let cur = store.selected else { return }
            store.createSnapshot(cur, name: vals[0])
            reload()
        }
    }

    /// 恢复 — 破坏性, 二次确认 (覆盖当前 disks/config/nvram/tpm).
    private func confirmRestore(_ s: SnapshotManager.Info) {
        Task { @MainActor in
            let r = await dialog.confirm(
                title: "恢复到快照 “\(s.name)”?",
                message: "当前的磁盘 / 配置 / NVRAM / TPM 将被该快照覆盖, 之后的改动丢失 (不可撤销). VM 须停机.",
                confirmLabel: "恢复",
                destructive: true,
                probeID: "detail.snapshot.confirm.restore-\(s.name)"
            )
            guard case .confirmed = r, let cur = store.selected else { return }
            store.restoreSnapshot(cur, name: s.name)
            reload()
        }
    }

    /// 删除快照 — 破坏性, 二次确认 (不动当前 VM).
    private func confirmDelete(_ s: SnapshotManager.Info) {
        Task { @MainActor in
            let r = await dialog.confirm(
                title: "删除快照 “\(s.name)”?",
                message: "该快照将被移除 (释放其占用空间), 当前 VM 不受影响. 不可撤销.",
                confirmLabel: "删除",
                destructive: true,
                probeID: "detail.snapshot.confirm.delete-\(s.name)"
            )
            guard case .confirmed = r, let cur = store.selected else { return }
            store.deleteSnapshot(cur, name: s.name)
            reload()
        }
    }
}
