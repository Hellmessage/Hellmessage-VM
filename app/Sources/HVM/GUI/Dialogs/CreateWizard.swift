// CreateWizard.swift — 新 GUI 创建向导业务装配 (业务页 #4).
//
// 不是新 dialog 组件: 复用扩展后的 HVMUI.WizardDialog (canAdvance gating + onComplete running 态),
// 这里只提供跨步 @Observable model + 3 个步骤视图 + steps() 构建器.
//
// 步骤 (D2=3 步 + 创建中; D4 加密独立步; D5 bridged 进 v1):
//   1 系统     — 名称 + Guest OS + 网络 (+bridged 接口)
//   2 介质与资源 — ISO + CPU/内存/磁盘 (+Windows 选项子区, 仅 windows)
//   3 加密     — encrypt toggle + 密码/确认
// onComplete → store.create(model.toCreateSpec()) (单一来源, 内部分流明文/加密).
//
// canAdvance 闭包在 WizardDialog.body 内被调用并读 @Observable model 属性,
// 故输入变化自动触发 "下一步/完成" disable 重算 (Observation 追踪).

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HVMBundle
import HVMControl
import HVMCore
import HVMStorage
import HVMInstall

// MARK: - 跨步 model

@MainActor
@Observable
final class CreateWizardModel {
    var name = ""
    var guestOS: GuestOSType = .linux
    var cpuText = "4"
    var memText = "4"
    var diskText = "64"
    var networkMode: NetworkMode = .user
    var bridgedInterface: String?
    var isoPath: String?
    var encrypt = false
    var password = ""
    var passwordConfirm = ""
    var win = WindowsSpec()

    /// 数值解析 (≥1 才有效, 否则 nil → canAdvance 拦)
    var cpu: Int?      { let v = Int(cpuText);    return (v ?? 0) >= 1 ? v : nil }
    var memGiB: UInt64? { let v = UInt64(memText);  return (v ?? 0) >= 1 ? v : nil }
    var diskGiB: UInt64? { let v = UInt64(diskText); return (v ?? 0) >= 1 ? v : nil }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func toCreateSpec() -> VMControl.CreateSpec {
        VMControl.CreateSpec(
            name: trimmedName,
            guestOS: guestOS,
            cpuCount: cpu ?? 4,
            memoryGiB: memGiB ?? 4,
            diskGiB: diskGiB ?? 64,
            networkMode: networkMode,
            bridgedInterface: networkMode == .vmnetBridged ? bridgedInterface : nil,
            macAddress: nil,
            installerISO: isoPath,
            parentDir: nil,
            windows: guestOS == .windows ? win : nil,
            encrypt: encrypt,
            password: encrypt ? password : nil
        )
    }
}

// MARK: - steps 构建器

enum CreateWizard {
    @MainActor
    static func steps(model: CreateWizardModel, store: NewGUIStore) -> [HVMUI.WizardStep] {
        [
            HVMUI.WizardStep(title: "系统", canAdvance: {
                let nm = model.trimmedName
                guard !nm.isEmpty,
                      !store.vms.contains(where: { $0.displayName == nm }) else { return false }
                if model.networkMode == .vmnetBridged {
                    return !(model.bridgedInterface ?? "").isEmpty
                }
                return true
            }) { AnyView(CreateStepSystem(model: model, store: store)) },

            HVMUI.WizardStep(title: "介质与资源", canAdvance: {
                model.isoPath != nil && model.cpu != nil && model.memGiB != nil && model.diskGiB != nil
            }) { AnyView(CreateStepMedia(model: model)) },

            HVMUI.WizardStep(title: "加密", canAdvance: {
                if !model.encrypt { return true }
                return model.password.count >= 4 && model.password == model.passwordConfirm
            }) { AnyView(CreateStepEncryption(model: model)) },
        ]
    }

    static func guestOSLabel(_ os: GuestOSType) -> String {
        switch os {
        case .linux:   return "Linux"
        case .windows: return "Windows (实验性 · QEMU)"
        }
    }

    static func networkModeLabel(_ m: NetworkMode) -> String {
        switch m {
        case .user:         return "NAT (推荐)"
        case .vmnetShared:  return "vmnet 共享"
        case .vmnetHost:    return "vmnet host"
        case .vmnetBridged: return "vmnet 桥接"
        case .none:         return "无网络"
        }
    }
}

// MARK: - Step 1: 系统

private struct CreateStepSystem: View {
    @Bindable var model: CreateWizardModel
    let store: NewGUIStore
    @State private var interfaces: [HostNetworkInterface] = []

    private var nameTaken: Bool {
        let nm = model.trimmedName
        return !nm.isEmpty && store.vms.contains(where: { $0.displayName == nm })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HVMUI.TextField("名称", text: $model.name,
                            placeholder: "我的虚拟机",
                            errorMessage: nameTaken ? "已存在同名 VM" : nil,
                            probeID: "dialog.create.field.name")

            HVMUI.Select("Guest OS", selection: $model.guestOS,
                         options: GuestOSType.allCases.map {
                             .init(value: $0, label: CreateWizard.guestOSLabel($0))
                         },
                         probeID: "dialog.create.select.os")
                .zIndex(3)

            if model.guestOS == .windows {
                Text("Windows on ARM 走 QEMU 后端, 实验性. 需自备 Win11 ARM64 ISO.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.warn)
            }

            HVMUI.Select("网络", selection: $model.networkMode,
                         options: NetworkMode.allCases.map {
                             .init(value: $0, label: CreateWizard.networkModeLabel($0))
                         },
                         probeID: "dialog.create.select.network")
                .zIndex(2)

            if model.networkMode == .vmnetBridged {
                HVMUI.Select("桥接接口", selection: $model.bridgedInterface,
                             options: interfaces.map { .init(value: $0.name, label: $0.displayLabel) },
                             placeholder: "选择物理接口...",
                             errorMessage: (model.bridgedInterface ?? "").isEmpty ? "桥接模式需选物理接口" : nil,
                             probeID: "dialog.create.select.bridgedIface")
                    .zIndex(1)
            }
        }
        .onAppear {
            interfaces = HostNetworkInterfaces.list()
            if model.networkMode == .vmnetBridged, (model.bridgedInterface ?? "").isEmpty {
                model.bridgedInterface = HostNetworkInterfaces.recommendedDefault()
            }
        }
    }
}

// MARK: - Step 2: 介质与资源

private struct CreateStepMedia: View {
    @Bindable var model: CreateWizardModel
    @State private var isoError: String?
    @State private var downloading = false
    @State private var downloadPct: Double = 0
    @State private var toolsReady = UtmGuestToolsCache.isReady

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            // ISO 选择
            VStack(alignment: .leading, spacing: HVMTheme.space.xs) {
                Text("安装 ISO")
                    .font(HVMTheme.font.sm)
                    .foregroundStyle(HVMTheme.color.textSecondary)
                HStack(spacing: HVMTheme.space.sm) {
                    Text(model.isoPath ?? "未选择")
                        .font(model.isoPath != nil ? HVMTheme.font.monoSm : HVMTheme.font.sm)
                        .foregroundStyle(model.isoPath != nil ? HVMTheme.color.textPrimary : HVMTheme.color.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HVMUI.Button("选择 ISO…", variant: .secondary,
                                 probeID: "dialog.create.iso.select") { selectISO() }
                    if model.isoPath != nil {
                        HVMUI.Button(icon: "xmark", variant: .icon, size: .sm,
                                     probeID: "dialog.create.iso.clear") {
                            model.isoPath = nil; isoError = nil
                        }
                    }
                }
                if let isoError {
                    Text(isoError).font(HVMTheme.font.xs).foregroundStyle(HVMTheme.color.error)
                }
            }

            // CPU / 内存 / 磁盘
            HStack(alignment: .top, spacing: HVMTheme.space.md) {
                HVMUI.TextField("CPU", text: $model.cpuText, placeholder: "4", suffix: "核",
                                errorMessage: model.cpu == nil ? "≥1" : nil,
                                probeID: "dialog.create.field.cpu")
                HVMUI.TextField("内存", text: $model.memText, placeholder: "4", suffix: "GiB",
                                errorMessage: model.memGiB == nil ? "≥1" : nil,
                                probeID: "dialog.create.field.memory")
                HVMUI.TextField("主盘", text: $model.diskText, placeholder: "64", suffix: "GiB",
                                errorMessage: model.diskGiB == nil ? "≥1" : nil,
                                probeID: "dialog.create.field.disk")
            }

            if model.guestOS == .windows {
                windowsOptions
            }
        }
    }

    @ViewBuilder
    private var windowsOptions: some View {
        HVMUI.Section("Windows 选项", variant: .elevated) {
            VStack(alignment: .leading, spacing: HVMTheme.space.sm) {
                HVMUI.Toggle("Secure Boot", isOn: $model.win.secureBoot,
                             probeID: "dialog.create.win.secureBoot")
                HVMUI.Toggle("TPM 2.0", isOn: $model.win.tpmEnabled,
                             probeID: "dialog.create.win.tpm")
                HVMUI.Toggle("跳过 Win11 硬件检查", isOn: $model.win.bypassInstallChecks,
                             hint: "TPM / Secure Boot / RAM / CPU 检查",
                             probeID: "dialog.create.win.bypassChecks")
                HVMUI.Toggle("首登自动装 SPICE 工具", isOn: $model.win.autoInstallSpiceTools,
                             hint: "含 vdagent (剪贴板/动态分辨率), 需 Windows 驱动工具",
                             probeID: "dialog.create.win.spiceTools")

                // Windows 驱动工具 (UTM Guest Tools) 前台下载
                HStack(spacing: HVMTheme.space.sm) {
                    HVMUI.Icon(toolsReady ? "checkmark.circle.fill" : "arrow.down.circle",
                               size: .sm, color: toolsReady ? .success : .secondary)
                    Text(toolsReady ? "Windows 驱动工具已就绪"
                         : (downloading ? "下载中 \(Int(downloadPct * 100))%…" : "Windows 驱动工具未下载"))
                        .font(HVMTheme.font.xs)
                        .foregroundStyle(HVMTheme.color.textSecondary)
                    Spacer()
                    if !toolsReady {
                        HVMUI.Button(downloading ? "下载中…" : "下载",
                                     variant: .secondary, size: .sm,
                                     disabled: downloading,
                                     probeID: "dialog.create.win.downloadTools") { downloadTools() }
                    }
                }
                .padding(.top, HVMTheme.space.xs)
            }
        }
    }

    private func selectISO() {
        // 测试钩子: NSOpenPanel 无法被 hvm-dbg gui 驱动 — probe 模式下若设了 HVM_TEST_ISO 直接用它,
        // 跳过 panel (与 probe server 同样仅在 HVM_GUI_PROBE 下生效, 真人用户无此 env, 不受影响).
        let env = ProcessInfo.processInfo.environment
        if env["HVM_GUI_PROBE"] != nil, let testISO = env["HVM_TEST_ISO"], !testISO.isEmpty {
            applyISO(testISO); return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyISO(url.path)
    }

    private func applyISO(_ path: String) {
        do {
            try ISOValidator.validate(at: path)
            model.isoPath = path
            isoError = nil
        } catch let e as HVMError {
            isoError = e.userFacing.message
        } catch {
            isoError = error.localizedDescription
        }
    }

    /// 前台下载 UTM Guest Tools (fail-soft: 失败只提示, 不阻创建).
    private func downloadTools() {
        downloading = true
        downloadPct = 0
        Task { @MainActor in
            do {
                _ = try await UtmGuestToolsCache.ensureCached { progress in
                    let f = progress.fraction ?? 0
                    Task { @MainActor in downloadPct = f }
                }
                toolsReady = UtmGuestToolsCache.isReady
            } catch {
                isoError = "驱动工具下载失败: \(error.localizedDescription) (可稍后在装机时再装)"
            }
            downloading = false
        }
    }
}

// MARK: - Step 3: 加密

private struct CreateStepEncryption: View {
    @Bindable var model: CreateWizardModel

    private var pwTooShort: Bool { model.encrypt && !model.password.isEmpty && model.password.count < 4 }
    private var pwMismatch: Bool { model.encrypt && !model.passwordConfirm.isEmpty && model.password != model.passwordConfirm }

    var body: some View {
        VStack(alignment: .leading, spacing: HVMTheme.space.md) {
            HVMUI.Toggle("加密此虚拟机", isOn: $model.encrypt,
                         hint: "整盘 LUKS 加密 (qcow2), 跨机器 portable",
                         probeID: "dialog.create.encrypt.toggle")

            if model.encrypt {
                HVMUI.SecureField("密码", text: $model.password,
                                  placeholder: "至少 4 字符",
                                  errorMessage: pwTooShort ? "至少 4 字符" : nil,
                                  autoFocus: true,
                                  probeID: "dialog.create.encrypt.password")
                HVMUI.SecureField("确认密码", text: $model.passwordConfirm,
                                  placeholder: "再次输入",
                                  errorMessage: pwMismatch ? "两次输入不一致" : nil,
                                  probeID: "dialog.create.encrypt.confirm")
                Text("⚠️ 忘记密码将无法恢复 VM 数据 (无后门). 请妥善保管.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("不加密 — VM 以明文 qcow2 存储, 任何能访问 bundle 的进程都可读.")
                    .font(HVMTheme.font.xs)
                    .foregroundStyle(HVMTheme.color.textTertiary)
            }
        }
    }
}
