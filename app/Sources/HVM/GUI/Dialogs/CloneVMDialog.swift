// CloneVMDialog.swift — 新 GUI 整 VM 克隆 dialog (form → running → done 三态).
//
// 走 NewGUIStore.clone → VMControl.clone (单一来源, APFS clonefile COW + 重生身份).
//   - 明文源: 只收新名 + keepMAC.
//   - 加密源: 额外收源密码 (CloneManager 自 unlock 源, 不用 GUI 解锁缓存); 克隆体同密码.
//   - running 态 X 不显 (clonefile 虽快, 但 detached 事务进行中不可关, 同加密事务 X-only-close).
//   - 失败回 form + 内联 error (store 不设全局 lastError, 避免双弹).
//   - Win guest: tpm/ 字节复制 → 与源同 BitLocker 状态, done 态提示双开会触发 recovery.
// store 显式传入 (dialog overlay 在 .environment(store) 外层拿不到环境), 同 NewGUIEncryptionDialog.
//
// 入口: DetailOverviewView actionButtons 的 [克隆] (仅 stopped 显) → dialog.present { CloneVMDialog(...) }.

import SwiftUI
import HVMControl
import HVMBundle

struct CloneVMDialog: View {
    let vm: VMSummary
    let handle: HVMUI.DialogHandle
    let store: NewGUIStore

    enum Phase: Equatable { case form, running, done }
    @State private var phase: Phase = .form
    @State private var newName: String = ""
    @State private var keepMAC: Bool = false
    @State private var password: String = ""
    @State private var inlineError: String?
    @State private var didInit = false

    private var isEncrypted: Bool { vm.isEncrypted }
    private var isWindows: Bool { vm.guestOS == .windows }
    private var isRunning: Bool { phase == .running }
    private let probeBase = "dialog.clone"

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            headerRow
            HVMUI.Divider(padding: .none)
            switch phase {
            case .form:    formView
            case .running: runningView
            case .done:    doneView
            }
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 480)
        .background(cardBackground)
        .animation(HVMTheme.motion.easeOut, value: phase)
        .onAppear {
            // 默认名: "<源> 副本" (去重); 只初始化一次
            if !didInit { newName = store.defaultCloneName(for: vm); didInit = true }
        }
    }

    // MARK: - header

    private var headerRow: some View {
        HStack(alignment: .top) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Icon("doc.on.doc.fill", size: .lg, color: .accent)
                Text("克隆虚拟机")
                    .font(HVMTheme.font.lg)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            Spacer()
            if !isRunning {
                HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                             probeID: "\(probeBase).close") { handle.close() }
            }
        }
    }

    // MARK: - form 态

    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text("源: \(vm.displayName)")
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)

            HVMUI.TextField("新名称", text: $newName,
                            placeholder: "克隆体名称",
                            errorMessage: nameTaken ? "已存在同名 VM" : nil,
                            probeID: "\(probeBase).field.name")

            if isEncrypted {
                HVMUI.SecureField("源密码", text: $password, placeholder: "加密源 VM 密码",
                                  autoFocus: false,
                                  probeID: "\(probeBase).field.password")
            }

            HVMUI.Toggle("保留 MAC 地址", isOn: $keepMAC,
                         hint: "默认重生 MAC; 保留则同 LAN 双开会冲突",
                         probeID: "\(probeBase).toggle.keepMac")

            Text("APFS clonefile 瞬时复制 (几乎不占额外空间). 新 VM 独立身份 (ID / MAC / 数据盘名重生)."
                 + (isEncrypted ? " 克隆体与源同密码 (想换密码克隆后自跑改密)." : ""))
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isWindows {
                Text("⚠️ Windows: tpm 状态字节复制 → 与源同 BitLocker; 源与克隆同时运行会触发 BitLocker recovery.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let inlineError {
                Text(inlineError)
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: HVMTheme.space.sm) {
                Spacer()
                HVMUI.Button("取消", variant: .secondary, probeID: "\(probeBase).cancel") {
                    handle.close()
                }
                HVMUI.Button("克隆", variant: .primary, disabled: !canSubmit,
                             probeID: "\(probeBase).confirm") { submit() }
            }
            .padding(.top, HVMTheme.space.xs)
        }
    }

    // MARK: - running 态

    private var runningView: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                ProgressView().scaleEffect(0.7)
                Text("正在克隆…")
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            Text("请勿关闭窗口")
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.warn)
        }
    }

    // MARK: - done 态

    private var doneView: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Icon("checkmark.circle.fill", size: .lg, color: .success)
                Text("克隆完成 · \(newName)")
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            if isEncrypted {
                Text("克隆体与源同密码, 启动时输入即可.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
            HStack {
                Spacer()
                HVMUI.Button("完成", variant: .primary, probeID: "\(probeBase).done") {
                    handle.close()
                }
            }
        }
    }

    // MARK: - 提交 / 校验

    private func submit() {
        phase = .running
        inlineError = nil
        let pw: String? = isEncrypted ? password : nil
        Task { @MainActor in
            let r = await store.clone(vm, newName: newName.trimmingCharacters(in: .whitespaces),
                                      keepMAC: keepMAC, password: pw)
            if r.ok {
                phase = .done
            } else {
                inlineError = r.error ?? "克隆失败"
                phase = .form
            }
        }
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool {
        !trimmedName.isEmpty && store.vms.contains { $0.displayName == trimmedName && $0.id != vm.id }
    }
    private var canSubmit: Bool {
        guard !trimmedName.isEmpty, !nameTaken else { return false }
        if isEncrypted && password.isEmpty { return false }
        return true
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
            .fill(HVMTheme.color.bgOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                    .stroke(HVMTheme.color.borderEmphasis, lineWidth: HVMTheme.border.hairline)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
            .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
    }
}
