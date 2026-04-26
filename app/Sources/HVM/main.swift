// HVM executable 主入口
// 根据 argv 分派到 GUI 模式或 VMHost 模式
// 详见 docs/ARCHITECTURE.md "进程模型"

import Foundation

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--host-mode-bundle" {
    // VMHost 模式: 接管指定 bundle, 启动 VM, 监听 IPC socket
    HVMHostEntry.run(bundlePath: args[2])
} else {
    // GUI 模式: AppKit NSApplication runloop
    HVMAppLauncher.run()
}
