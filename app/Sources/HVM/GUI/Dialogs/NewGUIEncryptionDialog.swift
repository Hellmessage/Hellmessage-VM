// NewGUIEncryptionDialog.swift — 新 GUI 整 VM 加密/解密/改密 三态 dialog (业务页 #3, E2).
//
// 一个参数化 dialog (mode: encrypt/decrypt/rekey) 共享 card/header/running/done chrome, 只 form
// 字段 + store 调用 + 文案按 mode 分. form → running → done 三态:
//   - running 态 X 不显 (closeAction=nil 语义, CLAUDE.md X-only-close + 加密事务不可中断)
//   - 失败回 form + 内联 error (store 不设全局 lastError, 避免双弹)
//   - Win guest 加密/改密重置 TPM → form + done 红字预警 (BitLocker recovery key 丢失)
// store 显式传入 (不走 @Environment): .hvmDialogHost() 在 .environment(store) 外层, dialog overlay
// 拿不到 store 环境. @Observable 仍按 body 内访问 store.encProgress 建立 observation.
//
// 入口: DetailEncryptionSection 通过 dialog.present { handle in NewGUIEncryptionDialog(...) }.


import SwiftUI
import HVMControl
import HVMBundle

struct NewGUIEncryptionDialog: View {
    enum Mode { case encrypt, decrypt, rekey }

    let vm: VMSummary
    let mode: Mode
    let handle: HVMUI.DialogHandle
    let store: NewGUIStore

    enum Phase: Equatable { case form, running, done(tpmReset: Bool) }
    @State private var phase: Phase = .form
    // encrypt: pwOld=设置密码, pwNew=确认密码
    // decrypt: pwOld=密码
    // rekey:   pwOld=原密码, pwNew=新密码, pwConfirm=确认新密码
    @State private var pwOld = ""
    @State private var pwNew = ""
    @State private var pwConfirm = ""
    @State private var inlineError: String?

    private var isWindows: Bool { vm.guestOS == .windows }
    private var showsTpm: Bool { isWindows && (mode == .encrypt || mode == .rekey) }
    private var isRunning: Bool { phase == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            headerRow
            HVMUI.Divider(padding: .none)
            switch phase {
            case .form:              formView
            case .running:           runningView
            case .done(let tpm):     doneView(tpmReset: tpm)
            }
        }
        .padding(HVMTheme.space.lg)
        .frame(width: 480)
        .background(cardBackground)
        .animation(HVMTheme.motion.easeOut, value: phase)
    }

    // MARK: - header

    private var headerRow: some View {
        HStack(alignment: .top) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Icon(headerIcon, size: .lg, color: .accent)
                Text(title)
                    .font(HVMTheme.font.lg)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            Spacer()
            // running 不可关 (X 不显)
            if !isRunning {
                HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                             probeID: "\(probeBase).close") { handle.close() }
            }
        }
    }

    // MARK: - form 态

    @ViewBuilder
    private var formView: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            Text(vm.displayName)
                .font(HVMTheme.font.sm)
                .foregroundStyle(HVMTheme.color.textSecondary)

            // 字段 (按 mode)
            switch mode {
            case .encrypt:
                secure("设置密码", $pwOld, "至少 4 字符", id: "password", autoFocus: true)
                secure("确认密码", $pwNew, "再次输入", id: "confirm", onEnter: true)
            case .decrypt:
                secure("密码", $pwOld, "请输入密码", id: "password", onEnter: true, autoFocus: true)
            case .rekey:
                secure("原密码", $pwOld, "当前密码", id: "old", autoFocus: true)
                secure("新密码", $pwNew, "至少 4 字符", id: "new")
                secure("确认新密码", $pwConfirm, "再次输入新密码", id: "confirm", onEnter: true)
            }

            // 警告
            warningText
            if showsTpm {
                Text("⚠️ Windows guest 将重置 TPM — BitLocker recovery key / TPM 密封密钥全部失效, 改密前请先在 guest 内备份恢复密钥.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
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
                HVMUI.Button(confirmLabel,
                             variant: mode == .decrypt ? .destructive : .primary,
                             disabled: !canSubmit,
                             probeID: "\(probeBase).confirm") { submit() }
            }
            .padding(.top, HVMTheme.space.xs)
        }
    }

    private var warningText: some View {
        let msg: String
        switch mode {
        case .encrypt: msg = "忘记密码将无法恢复 VM 数据 (无后门). 请妥善保管."
        case .decrypt: msg = "解密后数据不再受加密保护, 任何能访问 bundle 的进程都可读. 磁盘仍为 qcow2 格式."
        case .rekey:   msg = "改密用新 keyslot 重写; 旧密码改密后立即失效."
        }
        return Text(msg)
            .font(HVMTheme.font.xs)
            .foregroundStyle(HVMTheme.color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func secure(_ label: String, _ text: Binding<String>, _ placeholder: String,
                        id: String, onEnter: Bool = false, autoFocus: Bool = false) -> some View {
        HVMUI.SecureField(label, text: text, placeholder: placeholder,
                          autoFocus: autoFocus,
                          probeID: "\(probeBase).field.\(id)",
                          onSubmit: onEnter ? { if canSubmit { submit() } } : nil)
    }

    // MARK: - running 态

    private var runningView: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                ProgressView().scaleEffect(0.7)
                Text(runningLabel)
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            // 进度日志 (qemu-img 阶段输出)
            if !store.encProgress.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.encProgress.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(HVMTheme.font.monoSm)
                                .foregroundStyle(HVMTheme.color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .hvmHideScroller()
                }
                .frame(maxHeight: 140)
                .padding(HVMTheme.space.sm)
                .background(RoundedRectangle(cornerRadius: HVMTheme.radius.md)
                    .fill(HVMTheme.color.bgBase))
            }
            Text("请勿关闭窗口 — 中断可能损坏 VM" + (mode == .rekey ? " (两个密码都会解不开)" : ""))
                .font(HVMTheme.font.xs)
                .foregroundStyle(HVMTheme.color.warn)
        }
    }

    // MARK: - done 态

    private func doneView(tpmReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HStack(spacing: HVMTheme.space.sm) {
                HVMUI.Icon("checkmark.circle.fill", size: .lg, color: .success)
                Text(doneLabel)
                    .font(HVMTheme.font.base)
                    .foregroundStyle(HVMTheme.color.textPrimary)
            }
            if mode == .decrypt {
                Text("磁盘仍为 qcow2 格式 (未转 raw). VM 现在可正常启动/编辑配置.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
            if tpmReset {
                Text("⚠️ TPM 已重置 — 若 guest 启用了 BitLocker, 下次启动需输入 recovery key.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                HVMUI.Button("完成", variant: .primary, probeID: "\(probeBase).done") {
                    handle.close()
                }
            }
        }
    }

    // MARK: - 提交

    private func submit() {
        phase = .running
        inlineError = nil
        Task { @MainActor in
            let result: (ok: Bool, tpmReset: Bool, error: String?)
            switch mode {
            case .encrypt:
                result = await store.encrypt(vm, password: pwOld)
            case .decrypt:
                let r = await store.decrypt(vm, password: pwOld)
                result = (r.ok, false, r.error)
            case .rekey:
                result = await store.rekey(vm, oldPassword: pwOld, newPassword: pwNew)
            }
            if result.ok {
                phase = .done(tpmReset: result.tpmReset)
            } else {
                inlineError = result.error ?? "操作失败"
                phase = .form
            }
        }
    }

    // MARK: - 校验

    private var canSubmit: Bool {
        switch mode {
        case .encrypt: return pwOld.count >= 4 && pwOld == pwNew
        case .decrypt: return !pwOld.isEmpty
        case .rekey:   return !pwOld.isEmpty && pwNew.count >= 4
            && pwNew == pwConfirm && pwNew != pwOld
        }
    }

    // MARK: - mode 文案

    private var probeBase: String {
        switch mode {
        case .encrypt: return "dialog.encrypt"
        case .decrypt: return "dialog.decrypt"
        case .rekey:   return "dialog.rekey"
        }
    }
    private var title: String {
        switch mode {
        case .encrypt: return "加密虚拟机"
        case .decrypt: return "解密虚拟机"
        case .rekey:   return "修改密码"
        }
    }
    private var headerIcon: String {
        switch mode {
        case .encrypt: return "lock.fill"
        case .decrypt: return "lock.open.fill"
        case .rekey:   return "key.fill"
        }
    }
    private var confirmLabel: String {
        switch mode {
        case .encrypt: return "加密"
        case .decrypt: return "解密"
        case .rekey:   return "改密"
        }
    }
    private var runningLabel: String {
        switch mode {
        case .encrypt: return "正在加密 VM (磁盘转 LUKS, 可能数分钟)…"
        case .decrypt: return "正在解密 VM (磁盘转明文, 可能数分钟)…"
        case .rekey:   return "正在改密…"
        }
    }
    private var doneLabel: String {
        switch mode {
        case .encrypt: return "VM 已加密"
        case .decrypt: return "VM 已解密为明文"
        case .rekey:   return "密码已修改"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
            .fill(HVMTheme.color.bgOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: HVMTheme.radius.xl)
                    .stroke(HVMTheme.color.borderEmphasis,
                            lineWidth: HVMTheme.border.hairline)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
            .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
    }
}

