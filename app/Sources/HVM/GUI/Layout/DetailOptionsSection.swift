// DetailOptionsSection.swift — 详情页选项 section: 剪贴板共享 + macOS 风格快捷键.
//
// 两项都仅 QEMU 后端 (vdagent / 输入映射) 生效, 否则灰显 + 文案. 都可 running 热改 (requireStopped=false),
// 走 saveConfig / setClipboardSharing 自动分流明文/加密.


import SwiftUI
import HVMControl
import HVMBundle

struct DetailOptionsSection: View {
    let vm: VMSummary
    @Environment(NewGUIStore.self) private var store

    private var cfg: VMConfig? { vm.config }
    /// 仅 QEMU 后端有意义 (vdagent + 输入映射)
    private var supported: Bool { vm.engine == .qemu }

    var body: some View {
        if cfg != nil {
            HVMUI.Section("选项",
                          description: supported ? nil : "以下选项仅 QEMU 后端生效") {
                VStack(alignment: .leading, spacing: HVMTheme.space.md) {
                    HVMUI.Toggle("剪贴板共享 (host ↔ guest 文本)",
                                 isOn: clipboardBinding,
                                 hint: "运行中可即时切换 (vdagent)",
                                 size: .md, disabled: !supported,
                                 probeID: "detail.options.clipboard")
                    HVMUI.Toggle("macOS 风格快捷键 (⌘ → guest Ctrl)",
                                 isOn: macStyleBinding,
                                 hint: "开启后 ⌘C/⌘V 映射为 Ctrl+C/V; 失去发 Win 键能力",
                                 size: .md, disabled: !supported,
                                 probeID: "detail.options.macStyle")
                }
            }
        }
    }

    /// 剪贴板热改 binding: getter 读 live store.selected (非捕获渲染时 cfg, 防 probe 闭包 stale);
    /// setter 走 store.setClipboardSharing (落 config + running IPC)
    private var clipboardBinding: Binding<Bool> {
        Binding(
            get: { store.selected?.config?.clipboardSharingEnabled ?? false },
            set: { on in
                if let cur = store.selected { store.setClipboardSharing(cur, enabled: on) }
            }
        )
    }

    /// macStyle binding: 同上读 live; 切换即 saveConfig (requireStopped=false, 无须重启)
    private var macStyleBinding: Binding<Bool> {
        Binding(
            get: { store.selected?.config?.macStyleShortcuts ?? false },
            set: { on in
                guard let cur = store.selected else { return }
                store.saveConfig(cur, requireStopped: false) { $0.macStyleShortcuts = on }
            }
        )
    }
}

