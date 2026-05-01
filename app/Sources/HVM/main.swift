// HVM executable 主入口
// 根据 argv 分派到 GUI 模式或 VMHost 模式
// 详见 docs/ARCHITECTURE.md "进程模型"

import Foundation

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--host-mode-bundle" {
    // VMHost 模式: 接管指定 bundle, 启动 VM, 监听 IPC socket.
    // 可选 `--gui-embedded`: 由 GUI 主进程派生时传入, host 子进程跳过装自己的
    // menu bar status item (GUI 主进程自己已有), 避免重复图标.
    let embeddedInGUI = args.dropFirst(3).contains("--gui-embedded")
    HVMHostEntry.run(bundlePath: args[2], embeddedInGUI: embeddedInGUI)
} else {
    // GUI 模式: AppKit NSApplication runloop
    HVMAppLauncher.run()
}
