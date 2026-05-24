// SharedFolderDialog.swift
// host ↔ guest 共享目录添加弹窗 (SPICE WebDAV). 设计稿 docs/v3/SHARED_FOLDER.md.
//
// 用户在详情页 Sharing 区点 [+ 共享目录…] → NSOpenPanel 选 host 目录 → 本 dialog
// 弹出让用户起 name (默认目录 basename sanitize 后) + 选 读/写, [保存] 落盘.
//
// VM 必须 stopped + engine=qemu (DetailBars 已挡, dialog 内不重复校验).

import SwiftUI
import HVMBundle
import HVMCore
import HVMGuiProbe

struct SharedFolderDialog: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter
    let request: AppModel.SharedFolderAddRequest

    @State private var name: String = ""
    @State private var readOnly: Bool = true
    @State private var inlineError: String? = nil

    var body: some View {
        HVMModal(
            title: "添加共享目录",
            icon: .info,
            width: 560,
            closeAction: { close() }
        ) {
            VStack(alignment: .leading, spacing: HVMSpace.lg) {
                hostLine
                nameLine
                rwLine
                if let err = inlineError {
                    Text(err)
                        .font(HVMFont.small)
                        .foregroundStyle(HVMColor.danger)
                }
                Text("说明: 走 SPICE WebDAV. Win guest: \\\\localhost\\dav\\\(name.isEmpty ? "<name>" : name); Linux: GVFS davs://localhost/\(name.isEmpty ? "<name>" : name). 改动下次启动 VM 生效.")
                    .font(HVMFont.small)
                    .foregroundStyle(HVMColor.textTertiary)
            }
        } footer: {
            HVMModalFooter {
                Button("取消") { close() }
                    .buttonStyle(GhostButtonStyle())
                    .hvmProbe(id: "dialog.sharedFolder.button.cancel",
                              label: "取消",
                              action: .button { close() })
                Button("保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(name.isEmpty)
                    .hvmProbe(id: "dialog.sharedFolder.button.save",
                              label: "保存",
                              action: .button { save() })
            }
        }
        .onAppear {
            name = SharedFolderSpec.sanitizeName(request.hostURL.lastPathComponent)
        }
    }

    private var hostLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("host 目录")
            Text(request.hostURL.path)
                .font(HVMFont.mono)
                .foregroundStyle(HVMColor.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var nameLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            LabelText("名称 (guest 内可见的 WebDAV root)")
            HVMTextField("例: code, docs", text: $name)
                .hvmProbe(id: "dialog.sharedFolder.input.name",
                          label: "name",
                          action: .textField(getter: { name },
                                             setter: { name = $0 }))
            Text("仅允许 [a-zA-Z0-9_-], 长度 1–32. 单 VM 内唯一.")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
    }

    private var rwLine: some View {
        VStack(alignment: .leading, spacing: HVMSpace.xs) {
            HVMToggle(
                "允许 guest 写入 (RW)",
                isOn: Binding(
                    get: { !readOnly },
                    set: { readOnly = !$0 }
                ),
                help: "默认只读, 防 guest 误删/改 host 文件. 开发场景 (代码同步) 勾上"
            )
            .hvmProbe(id: "dialog.sharedFolder.toggle.readOnly",
                      label: "read-only",
                      action: .toggle(getter: { readOnly },
                                      setter: { readOnly = $0 }))
            Text(readOnly
                 ? "只读: guest 只能读 host 文件, 写操作返 403"
                 : "可写: guest 可在 host 目录内创建 / 修改 / 删除文件")
                .font(HVMFont.small)
                .foregroundStyle(HVMColor.textTertiary)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else {
            inlineError = "名称需 1–32 字符"
            return
        }
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else {
            inlineError = "名称仅允许 [a-zA-Z0-9_-]"
            return
        }
        let spec = SharedFolderSpec(hostPath: request.hostURL.path,
                                     name: trimmed, readOnly: readOnly)
        do {
            try model.addSharedFolder(item: request.item, spec: spec)
            close()
        } catch let e as HVMError {
            inlineError = e.localizedDescription
        } catch {
            inlineError = "\(error)"
        }
    }

    private func close() {
        model.sharedFolderAddRequest = nil
    }
}
