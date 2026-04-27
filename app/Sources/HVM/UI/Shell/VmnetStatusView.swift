// HVM/UI/Shell/VmnetStatusView.swift
// 主窗口底部 statusBar 上的 vmnet 状态 chip + 点击弹 popover.
//
// 设计意图: 让用户一眼看到 socket_vmnet daemon 是否就绪 (shared / host / bridged.<iface>),
// 出现问题时点 chip 直接跑安装/重启引导, 而不需要去翻 docs.
//
// 数据源: 扫 /Library/LaunchDaemons/*.plist 找含 socket_vmnet 的 plist (HVM/lima/colima/
// hell-vm 等共存项目都装在这里), 解析 plist 拿到 label + socket path, 再 stat socket file
// 判断状态:
//   - ready:  socket file 存在且是 unix socket → daemon 工作中
//   - zombie: plist 存在但 socket file 缺/类型错 → daemon 进程僵了 (常见: 别的工具 rm 过
//             socket, 或 daemon 进程崩溃后 launchd 没拉起来), 给用户一个 "重启 daemon" 入口
//   - missing 状态由 chip 数量差体现 (plist 数 - ready 数), 不单独建条目
//
// 注意: stat 检测**不能**判断 daemon 是否"假死" (kernel 仍 accept 连接但 accept loop 死),
// 那种情况只能 connect 探针, 当前不做.

import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Model

@MainActor
@Observable
public final class VmnetStatusModel {

    public struct Entry: Identifiable, Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case shared
            case host
            case bridged(interface: String)
            case unknown(String)        // 罕见: plist args 解析不到 mode, 当 fallback
        }
        public enum State: Sendable, Hashable {
            case ready                   // socket file 存在且是 unix socket
            case zombie                  // plist 装了但 socket file 缺/类型错; 可 kickstart 修
        }

        public let kind: Kind
        /// launchd plist label, 如 "com.hellmessage.hvm.vmnet.shared" / "io.hell.vmnet.bridged.en11".
        /// kickstart / uninstall 时用 launchctl 走 system/<label>.
        public let label: String
        /// /Library/LaunchDaemons/<label>.plist 绝对路径 (uninstall 时 rm 它).
        public let plistPath: String
        public let socketPath: String
        public let state: State

        public var id: String { label }

        public var displayName: String {
            switch kind {
            case .shared:                 return "shared"
            case .host:                   return "host"
            case .bridged(let iface):     return "bridged · \(iface)"
            case .unknown(let suffix):    return suffix
            }
        }
    }

    public private(set) var entries: [Entry] = []

    public var anyReady: Bool { entries.contains { $0.state == .ready } }
    public var allReady: Bool { !entries.isEmpty && entries.allSatisfy { $0.state == .ready } }
    public var readyCount: Int { entries.lazy.filter { $0.state == .ready }.count }
    public var totalCount: Int { entries.count }
    public var zombieCount: Int { entries.lazy.filter { $0.state == .zombie }.count }

    private var timer: Timer?

    public init() {
        refresh()
    }

    /// 启 2s 轮询. 由 HVMApp 在主窗口创建后启一次; 不重复启
    public func startPolling() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// 扫 /Library/LaunchDaemons/*.plist 找含 socket_vmnet 的 plist, 解析 label +
    /// socket path + 模式, 再 stat socket file 判 ready / zombie. 普通用户可读 plist 目录.
    public func refresh() {
        let plistDir = "/Library/LaunchDaemons"
        var found: [Entry] = []

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: plistDir) else {
            entries = []
            return
        }

        for name in names where name.hasSuffix(".plist") {
            // 文件名快速过滤: 不含 vmnet keyword 大概率不是; 节省 PropertyList 解析
            let lower = name.lowercased()
            if !lower.contains("vmnet") && !lower.contains("socket_vmnet") { continue }

            let plistPath = "\(plistDir)/\(name)"
            guard let entry = parsePlist(path: plistPath) else { continue }
            found.append(entry)
        }

        // 排序: shared → host → bridged (按 iface 字典序) → unknown
        found.sort { lhs, rhs in
            func rank(_ k: Entry.Kind) -> Int {
                switch k {
                case .shared: return 0
                case .host: return 1
                case .bridged: return 2
                case .unknown: return 3
                }
            }
            let r = (rank(lhs.kind), rank(rhs.kind))
            if r.0 != r.1 { return r.0 < r.1 }
            return lhs.displayName < rhs.displayName
        }
        entries = found
    }

    /// 解析单个 plist 文件 → Entry (不是 socket_vmnet daemon 返 nil).
    /// plist 不必出自 HVM 自己装的, lima / hell-vm / colima 等同形态也认得出来.
    private func parsePlist(path: String) -> Entry? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any]
        else { return nil }

        guard let label = dict["Label"] as? String else { return nil }
        guard let args = dict["ProgramArguments"] as? [String], !args.isEmpty else { return nil }

        // 第一个参数是 binary; 路径末段是 socket_vmnet 才算
        let binBasename = (args[0] as NSString).lastPathComponent
        guard binBasename == "socket_vmnet" else { return nil }

        // socket path 约定: socket_vmnet 把最后一个非选项参数当 socket path,
        // HVM/lima/hell-vm 都这么写. 取末项, 必须以 / 开头 (绝对路径)
        guard let sockPath = args.last, sockPath.hasPrefix("/") else { return nil }

        // 模式从 --vmnet-mode=<x> 与 --vmnet-interface=<iface> 推
        var mode: String? = nil
        var iface: String? = nil
        for a in args {
            if a.hasPrefix("--vmnet-mode=") { mode = String(a.dropFirst("--vmnet-mode=".count)) }
            if a.hasPrefix("--vmnet-interface=") { iface = String(a.dropFirst("--vmnet-interface=".count)) }
        }
        let kind: Entry.Kind
        switch mode {
        case "shared":  kind = .shared
        case "host":    kind = .host
        case "bridged":
            if let iface, !iface.isEmpty {
                kind = .bridged(interface: iface)
            } else {
                kind = .unknown(label)
            }
        default:        kind = .unknown(label)
        }

        // 状态: socket file 存在且是 unix socket → ready; 否则 zombie (plist 装了但 socket 缺)
        var st = stat()
        let state: Entry.State =
            (stat(sockPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK)
            ? .ready
            : .zombie

        return Entry(kind: kind, label: label, plistPath: path, socketPath: sockPath, state: state)
    }
}

// MARK: - Chip (statusBar 上的小入口)

struct VmnetStatusChip: View {
    @Bindable var model: VmnetStatusModel
    @State private var showPopover: Bool = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VmnetStatusPopover(model: model)
        }
    }

    private var label: String {
        if model.totalCount == 0 { return "vmnet" }
        if model.zombieCount > 0 {
            return "vmnet · \(model.zombieCount) broken"
        }
        if model.allReady { return "vmnet" }
        return "vmnet \(model.readyCount)/\(model.totalCount)"
    }

    private var dotColor: Color {
        if model.totalCount == 0 { return HVMColor.textTertiary }     // 未装: 灰
        if model.zombieCount > 0 { return HVMColor.statusError }      // 僵尸: 红 (需修)
        if model.allReady { return HVMColor.statusRunning }           // 全 ready: 绿
        return HVMColor.statusPaused                                  // 部分: 黄
    }

    private var tooltip: String {
        if model.totalCount == 0 {
            return "未安装 socket_vmnet daemon (点击查看安装引导)"
        }
        if model.zombieCount > 0 {
            return "\(model.zombieCount) 个 daemon plist 装了但 socket 缺失 (点击重启修复)"
        }
        return "vmnet: \(model.readyCount) / \(model.totalCount) daemon ready"
    }
}

// MARK: - Popover

struct VmnetStatusPopover: View {
    @Bindable var model: VmnetStatusModel
    @State private var lastInstallOutcome: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: HVMSpace.md) {
            Text("vmnet daemons")
                .font(HVMFont.heading.weight(.semibold))
                .foregroundStyle(HVMColor.textPrimary)

            if model.entries.isEmpty {
                Text("未安装 socket_vmnet daemon")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
                Text("QEMU 后端的 bridged / shared 网络需要先一次性 sudo 安装 helper.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.entries) { entry in
                        VmnetEntryRow(
                            entry: entry,
                            onKickstart: { kickstart(label: entry.label) },
                            onUninstall: { uninstall(entry: entry) }
                        )
                    }
                }
            }

            Divider().background(HVMColor.border)

            // 引导按钮: shared+host (无参数) + 列出当前所有物理 iface 让用户挑桥接
            VStack(alignment: .leading, spacing: HVMSpace.sm) {
                Button {
                    runInstall(extraArgs: [])
                } label: {
                    Text(model.entries.isEmpty ? "安装 vmnet helper (shared + host)" : "重装 / 修复 shared + host")
                        .font(HVMFont.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(GhostButtonStyle())

                Text("加 bridged 接口需要在终端跑命令并指定接口名:")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                Text("sudo bash <install-vmnet-helper.sh> en0 en1 ...")
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)

                Text("ready 也可能由 lima / colima / hell-vm 等共存项目提供; HVM 不会跟它们抢同一 socket.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let msg = lastInstallOutcome {
                    Text(msg)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(HVMSpace.lg)
        .frame(width: 320)
        .background(HVMColor.bgSidebar)
    }

    private func runInstall(extraArgs: [String]) {
        let outcome = VmnetSetupHelper.runInstallScript(extraArgs: extraArgs)
        switch outcome {
        case .launched:
            lastInstallOutcome = "已在 Terminal 中拉起脚本, 按提示输入 sudo 密码."
        case .fallbackCommand(let cmd):
            VmnetSetupHelper.copyToClipboard(cmd)
            lastInstallOutcome = "未能自动拉起 Terminal, 命令已复制到剪贴板."
        case .scriptMissing:
            lastInstallOutcome = "找不到 install-vmnet-helper.sh (HVM.app 资源不全, 请重 make build)."
        }
        // 装完用户回来时, timer 会自动 refresh 状态
    }

    fileprivate func kickstart(label: String) {
        let outcome = VmnetSetupHelper.kickstartDaemon(label: label)
        switch outcome {
        case .launched:
            lastInstallOutcome = "已在 Terminal 拉起 kickstart 命令, 输入 sudo 密码后 daemon 会重启."
        case .fallbackCommand(let cmd):
            VmnetSetupHelper.copyToClipboard(cmd)
            lastInstallOutcome = "未能拉起 Terminal, kickstart 命令已复制到剪贴板."
        case .scriptMissing:
            lastInstallOutcome = "kickstart 内部错误 (label 校验失败)."
        }
    }

    fileprivate func uninstall(entry: VmnetStatusModel.Entry) {
        let outcome = VmnetSetupHelper.uninstallDaemon(
            label: entry.label,
            plistPath: entry.plistPath,
            socketPath: entry.socketPath
        )
        switch outcome {
        case .launched:
            lastInstallOutcome = "已在 Terminal 拉起卸载命令 (\(entry.label)), 输入 sudo 密码确认."
        case .fallbackCommand(let cmd):
            VmnetSetupHelper.copyToClipboard(cmd)
            lastInstallOutcome = "未能拉起 Terminal, 卸载命令已复制到剪贴板."
        case .scriptMissing:
            lastInstallOutcome = "卸载内部错误 (label / 路径校验失败)."
        }
    }
}

// MARK: - 单行 entry 视图

private struct VmnetEntryRow: View {
    let entry: VmnetStatusModel.Entry
    let onKickstart: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(entry.displayName)
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            switch entry.state {
            case .ready:
                Text("ready")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            case .zombie:
                Text("daemon 僵了")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.statusError)
                Button {
                    onKickstart()
                } label: {
                    Text("重启").font(HVMFont.small)
                }
                .buttonStyle(GhostButtonStyle())
            }
            Button {
                onUninstall()
            } label: {
                Text("卸载").font(HVMFont.small)
            }
            .buttonStyle(GhostButtonStyle(destructive: true))
            .help("bootout + 删 plist + 删 socket (\(entry.label))")
        }
    }

    private var dotColor: Color {
        switch entry.state {
        case .ready:   return HVMColor.statusRunning
        case .zombie:  return HVMColor.statusError
        }
    }
}
