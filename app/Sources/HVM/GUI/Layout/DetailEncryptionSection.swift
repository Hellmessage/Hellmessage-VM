// DetailEncryptionSection.swift — 详情页"加密"section + 加密事务入口 (业务页 #3, E2).
//
// 放详情页最底 (破坏性重操作沉底). 按 VM 加密状态显不同入口:
//   - 明文 + QEMU + 非 macOS: "未加密" + [加密 VM…]
//   - 加密 qemuPerfile:        "已加密 · qemu-perfile" + [改密…] + [解密…]
//   - 加密 vzSparsebundle:     灰显 "VZ 加密 GUI 暂未接入 (走 hvm-cli)"
//   - macOS guest / VZ 明文:   灰显 "不支持整盘加密 (仅 QEMU + Linux/Windows)"
// 解密/改密 不要求先解锁 (dialog 自收密码). 入口仅 stopped 可点. 动作读 store.selected
// 防 stale probe 闭包 (同 VM_DETAIL 约束). 事务走 NewGUIEncryptionDialog 三态 dialog.


import SwiftUI
import HVMControl
import HVMBundle

struct DetailEncryptionSection: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store
    @EnvironmentObject private var dialog: HVMUI.DialogPresenter

    /// 明文可加密: QEMU + 非 macOS guest
    private var canEncryptPlaintext: Bool { vm.engine == .qemu && vm.guestOS != .macOS }
    private var editable: Bool { vm.runState == .stopped }

    var body: some View {
        HVMUI.Section("加密") {
            VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                if vm.isEncrypted {
                    encryptedContent
                } else if canEncryptPlaintext {
                    plaintextContent
                } else {
                    unsupportedContent
                }
            }
        }
    }

    // MARK: - 明文 (可加密)

    private var plaintextContent: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Badge("未加密", variant: .neutral, icon: "lock.open", size: .sm)
                Spacer()
                HVMUI.Button("加密 VM", variant: .primary, icon: "lock.fill", size: .sm,
                             disabled: !editable, probeID: "detail.encryption.encrypt") {
                    present(.encrypt)
                }
            }
            Text("整盘加密 (qcow2 LUKS + config AES-GCM + swtpm key). 冷迁移, 需停机; 忘密不可恢复."
                 + (editable ? "" : " 停止 VM 后可加密."))
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 已加密

    @ViewBuilder
    private var encryptedContent: some View {
        let isQemuPerfile = vm.encryptionScheme == .qemuPerfile
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Badge("已加密 · \(vm.encryptionScheme?.rawValue ?? "?")",
                            variant: .accent, icon: "lock.fill", size: .sm)
                Spacer()
                if isQemuPerfile {
                    HVMUI.Button("改密", variant: .secondary, icon: "key.fill", size: .sm,
                                 disabled: !editable, probeID: "detail.encryption.rekey") {
                        present(.rekey)
                    }
                    HVMUI.Button("解密", variant: .destructive, icon: "lock.open", size: .sm,
                                 disabled: !editable, probeID: "detail.encryption.decrypt") {
                        present(.decrypt)
                    }
                }
            }
            if isQemuPerfile {
                Text("改密 / 解密需停机, dialog 内输入密码 (无须先解锁)."
                     + (editable ? "" : " 停止 VM 后可操作."))
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            } else {
                Text("VZ-sparsebundle 加密事务 GUI 暂未接入, 请走 hvm-cli (decrypt / rekey).")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
        }
    }

    // MARK: - 不支持 (macOS guest / VZ 明文)

    private var unsupportedContent: some View {
        Text("当前 VM (\(vm.engine.rawValue.uppercased()) / \(vm.guestOS.rawValue)) 不支持整盘加密 (仅 QEMU 后端 + Linux/Windows guest).")
            .font(HVMTheme.font.sm)
            .foregroundStyle(HVMTheme.color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - present 事务 dialog (读 store.selected 防 stale)

    private func present(_ mode: NewGUIEncryptionDialog.Mode) {
        guard let cur = store.selected else { return }
        let s = store
        dialog.present { handle in
            NewGUIEncryptionDialog(vm: cur, mode: mode, handle: handle, store: s)
        }
    }
}

