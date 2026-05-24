// FileTransferDialog.swift
// host ↔ guest 单文件传输弹窗 (qemu-guest-agent guest-file-* API).
//
// 设计稿: docs/v3/FILE_COPY.md PR-D.
// 状态机: form → running → done / error → 关闭.
// 不支持取消 (D5: v1 cancel 按钮只 close modal, 后台 chunk 跑完才退. 不可中断期间隐藏 X).
//
// 2026-05-24: pull 路径加 inline guest 文件浏览器 — 点 [浏览…] 展开列表区,
// 走 IPC dbg.dir.list → guest qemu-ga PowerShell/find. 点目录下钻, 点文件选中回填.

import SwiftUI
import HVMBundle
import HVMCore
import HVMGuiProbe
import HVMIPC

struct FileTransferDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let request: AppModel.FileTransferRequest

    @State private var remotePath: String = ""
    @State private var phase: Phase = .form
    @State private var inlineError: String? = nil
    @State private var resultBytes: Int64 = 0
    @State private var resultDurationMs: Int64 = 0
    @State private var transferTask: Task<Void, Never>? = nil

    // pull 浏览器状态 (仅 pull 用)
    @State private var browserExpanded: Bool = false
    @State private var browserPath: String = ""
    @State private var browserEntries: [IPCDbgListDirPayload.Entry]? = nil  // nil = loading
    @State private var browserError: String? = nil
    @State private var browserLoadTask: Task<Void, Never>? = nil

    private enum Phase { case form, running, done }

    private var isPush: Bool { request.direction == .push }
    private var titleText: String { isPush ? "传文件到 VM" : "从 VM 取文件" }
    private var hostLabel: String { isPush ? "host 源文件" : "host 保存到" }
    private var remoteLabel: String { isPush ? "guest 目标路径" : "guest 源路径" }
    private var remoteHint: String { isPush ? "(覆盖目标)" : "" }

    var body: some View {
        HVMModal(
            title: titleText,
            icon: .info,
            width: 560,
            // 传输中不可关 (chunk 循环 best-effort 跑完); 其它阶段允许 X
            closeAction: phase == .running ? nil : { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                hostLine
                remoteLine
                if browserExpanded {
                    browserSection
                }
                statusBlock
            }
        } footer: {
            HVMModalFooter {
                footerButtons
            }
        }
        .onAppear {
            remotePath = request.suggestedRemotePath
        }
        .onDisappear {
            transferTask?.cancel()
            browserLoadTask?.cancel()
        }
    }

    private var hostLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText(hostLabel)
            if isPush {
                // push: hostURL 就是源文件全路径
                Text(request.hostURL.path)
                    .font(HVMFont.mono)
                    .foregroundStyle(HVMColor.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                // pull: hostURL 是目标**文件夹**, 文件名 = guest 源路径 basename. 动态预览.
                let folder = request.hostURL.path
                let trimmed = remotePathTrim
                if trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(folder)/")
                            .font(HVMFont.mono)
                            .foregroundStyle(HVMColor.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("(填好 guest 源路径后自动用同名)")
                            .font(HVMFont.small)
                            .foregroundStyle(HVMColor.textTertiary)
                    }
                } else {
                    let base = AppModel.deriveLocalBasename(fromGuestPath: trimmed)
                    Text("\(folder)/\(base)")
                        .font(HVMFont.mono)
                        .foregroundStyle(HVMColor.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var remoteLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("\(remoteLabel) \(remoteHint)")
            HStack(spacing: HVMSpace.sm) {
                HVMTextField(
                    isPush ? "C:\\path\\file 或 /tmp/file" : "guest 内绝对路径",
                    text: $remotePath
                )
                .disabled(phase != .form)
                .hvmProbe(id: "dialog.fileTransfer.input.remotePath",
                          label: remoteLabel,
                          action: .textField(getter: { remotePath },
                                             setter: { remotePath = $0 }))
                if !isPush {
                    // 仅 pull 路径暴露浏览器 — push 的 dst 用户自定, 浏览器对 push 价值低 (而且 push 还需创建不存在路径)
                    Button(action: { toggleBrowser() }) {
                        HStack(spacing: 4) {
                            Image(systemName: browserExpanded ? "chevron.down" : "folder")
                                .font(HVMFont.small)
                            Text(browserExpanded ? "收起" : "浏览…").font(HVMFont.caption)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(phase != .form)
                    .help("浏览 guest 内目录 (走 qemu-guest-agent)")
                    .hvmProbe(id: "dialog.fileTransfer.button.browse",
                              label: browserExpanded ? "Collapse" : "Browse",
                              action: .button { toggleBrowser() })
                }
            }
        }
    }

    /// guest 浏览器区 — 路径 bar + 上一级 + 刷新 + 文件列表
    private var browserSection: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            HStack(spacing: HVMSpace.xs) {
                Button(action: { goUp() }) {
                    Image(systemName: "arrow.up").font(HVMFont.small)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!canGoUp())
                .help("上一级")

                Button(action: { reload() }) {
                    Image(systemName: "arrow.clockwise").font(HVMFont.small)
                }
                .buttonStyle(IconButtonStyle())
                .help("刷新")

                Text(browserPath.isEmpty ? "—" : browserPath)
                    .font(HVMFont.monoSmall)
                    .foregroundStyle(HVMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, HVMSpace.sm)
            .padding(.vertical, HVMSpace.xs)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.sm)
                    .stroke(HVMColor.border, lineWidth: 1)
            )

            browserListView
        }
    }

    @ViewBuilder
    private var browserListView: some View {
        if let err = browserError {
            Text(err)
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                .padding(HVMSpace.sm)
                .background(HVMColor.bgCard)
                .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm).stroke(HVMColor.border, lineWidth: 1))
        } else if browserEntries == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("列目录中…").font(HVMFont.caption).foregroundStyle(HVMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(HVMColor.bgCard)
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm).stroke(HVMColor.border, lineWidth: 1))
        } else if let entries = browserEntries {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text("(空目录)")
                            .font(HVMFont.caption)
                            .foregroundStyle(HVMColor.textTertiary)
                            .padding(HVMSpace.sm)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Button(action: { onEntryTap(entry) }) {
                            HStack(spacing: HVMSpace.sm) {
                                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                                    .font(HVMFont.label)
                                    .foregroundStyle(entry.isDir ? HVMColor.statusRunning : HVMColor.textSecondary)
                                    .frame(width: 18)
                                Text(entry.name)
                                    .font(HVMFont.caption)
                                    .foregroundStyle(HVMColor.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                if !entry.isDir {
                                    Text(humanBytes(entry.size))
                                        .font(HVMFont.small)
                                        .foregroundStyle(HVMColor.textTertiary)
                                }
                            }
                            .padding(.horizontal, HVMSpace.sm)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .background(HVMColor.bgCard)
            .overlay(RoundedRectangle(cornerRadius: HVMRadius.sm).stroke(HVMColor.border, lineWidth: 1))
        }
    }

    private func toggleBrowser() {
        if browserExpanded {
            browserExpanded = false
            browserLoadTask?.cancel()
            return
        }
        // 打开: 先用 remotePath (若已填) 推父目录, 否则按 guestOS 默认起点
        let initial = initialBrowsePath()
        browserPath = initial
        browserExpanded = true
        reload()
    }

    /// 起始浏览路径: 若 remotePath 非空, 用它的父目录; 否则按 guestOS 默认 (Win `C:\`; Linux `/`).
    private func initialBrowsePath() -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 推父目录: Win `\` / Linux `/` 都识
            if let lastSep = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                let parent = String(trimmed[..<lastSep])
                // 处理 `C:` 这种 (lastSep 之前没东西) — 加回根斜杠
                if parent.isEmpty {
                    return String(trimmed[trimmed.startIndex...lastSep])
                }
                // Windows `C:` 缺尾斜杠时补
                if parent.hasSuffix(":") {
                    return parent + "\\"
                }
                return parent
            }
        }
        switch request.item.config?.guestOS {
        case .windows: return "C:\\"
        case .linux:   return "/"
        default:       return "/"
        }
    }

    private func canGoUp() -> Bool {
        // 根目录不能再上 (Win 暂仅支持 C:\ — 用户想跨盘自己手填)
        let p = browserPath
        if p == "C:\\" || p == "/" || p.isEmpty { return false }
        return true
    }

    private func goUp() {
        let p = browserPath
        guard p != "C:\\" && p != "/" else { return }
        // 去掉尾部斜杠后, 找最后一个 `\` 或 `/`
        var s = p
        while s.last == "/" || s.last == "\\" { s.removeLast() }
        if let lastSep = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            var parent = String(s[..<lastSep])
            if parent.hasSuffix(":") { parent += "\\" }       // Win: `C:` → `C:\`
            if parent.isEmpty { parent = "/" }                 // Linux: 根
            browserPath = parent
        } else {
            // 顶到根
            browserPath = p.contains("\\") ? "C:\\" : "/"
        }
        reload()
    }

    private func reload() {
        browserLoadTask?.cancel()
        browserError = nil
        browserEntries = nil  // loading
        let path = browserPath
        browserLoadTask = Task { @MainActor in
            do {
                let payload = try await model.listGuestDir(item: request.item, path: path)
                guard !Task.isCancelled, browserPath == path else { return }
                browserEntries = payload.entries
            } catch {
                guard !Task.isCancelled, browserPath == path else { return }
                browserError = "列目录失败: \(error.localizedDescription)"
                browserEntries = []  // 标记为非 loading
            }
        }
    }

    private func onEntryTap(_ entry: IPCDbgListDirPayload.Entry) {
        if entry.isDir {
            browserPath = entry.fullPath
            reload()
        } else {
            remotePath = entry.fullPath
            browserExpanded = false  // 选中文件后自动收起
            browserLoadTask?.cancel()
        }
    }

    private func humanBytes(_ n: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = Double(n)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch phase {
        case .form:
            if let msg = inlineError {
                Text(msg)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(hintText)
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .running:
            HStack(spacing: HVMSpace.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("传输中... (本通路 1-10 MB/s; 大文件请耐心等待)")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textSecondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: HVMSpace.xs) {
                Text("✓ 传输完成")
                    .font(HVMFont.caption)
                    .foregroundStyle(HVMColor.textPrimary)
                Text(doneSummary)
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textSecondary)
            }
        }
    }

    private var hintText: String {
        if isPush {
            return "通过 qemu-guest-agent 写入 guest. 中断会留半成品 dst (v1 限制). VM 必须在跑且 qemu-ga 服务已启动."
        } else {
            return "从 guest 读出来. 本地走 .hvm-tmp + 原子 rename, 中断不留残留. VM 必须在跑且 qemu-ga 服务已启动."
        }
    }

    private var doneSummary: String {
        let mb = Double(resultBytes) / (1024.0 * 1024.0)
        let secs = Double(resultDurationMs) / 1000.0
        let mbps = secs > 0.001 ? mb / secs : 0
        return String(format: "%.2f MiB · %.2fs · %.2f MB/s", mb, secs, mbps)
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch phase {
        case .form:
            Button("取消") { close() }
                .buttonStyle(GhostButtonStyle())
                .hvmProbe(id: "dialog.fileTransfer.button.cancel",
                          label: "取消",
                          action: .button { close() })
            Button(isPush ? "开始传输" : "开始拉取") { start() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(remotePathTrim.isEmpty)
                .hvmProbe(id: "dialog.fileTransfer.button.start",
                          label: "开始",
                          action: .button { start() })
        case .running:
            // 不可中断 — X 已隐藏, footer 留空 (footer Body required, 用 EmptyView 类似)
            Text("")
                .font(HVMFont.caption)
                .foregroundStyle(HVMColor.textTertiary)
        case .done:
            Button("关闭") { close() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [])
                .hvmProbe(id: "dialog.fileTransfer.button.close",
                          label: "关闭",
                          action: .button { close() })
        }
    }

    private var remotePathTrim: String {
        remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func close() {
        transferTask?.cancel()
        model.fileTransferRequest = nil
    }

    private func start() {
        let path = remotePathTrim
        guard !path.isEmpty else { return }
        inlineError = nil
        // pull: request.hostURL 是文件夹, 最终保存路径 = folder + guest basename
        let finalHostURL: URL
        if isPush {
            finalHostURL = request.hostURL
        } else {
            let base = AppModel.deriveLocalBasename(fromGuestPath: path)
            finalHostURL = request.hostURL.appendingPathComponent(base)
        }
        phase = .running
        transferTask = Task { @MainActor in
            do {
                let result = try await model.runFileTransfer(
                    item: request.item,
                    direction: request.direction,
                    hostURL: finalHostURL,
                    remotePath: path
                )
                resultBytes = result.bytes
                resultDurationMs = result.durationMs
                phase = .done
            } catch {
                inlineError = "\(error.localizedDescription)"
                phase = .form
            }
        }
    }
}
