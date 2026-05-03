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

    // 加密 VM password 通过 stdin 透传 (HostLauncher / GUI spawnExternalHost 写 + close).
    // 协议: 父进程 write password + close write 端; 子进程 read until EOF (1s timeout).
    //   - 空内容 = 明文 VM (父进程立即 close write 端, 不写)
    //   - 非空 = 加密 VM, password = 读到的 utf-8 字符串
    // stdin 是 fd=0, 永远存在 (默认 Process 也透传); 设 1s timeout 防意外阻塞.
    let password: String? = {
        let stdin = FileHandle.standardInput
        // 给父进程 1s 写完 + close. 大多数情况是 ms 级 (本地 pipe).
        let deadline = Date().addingTimeInterval(1.0)
        var buf = Data()
        // 走非阻塞 read: poll fd 走 select, 这里简化 — 用 readToEnd 阻塞读, 但靠
        // 父进程已 close 而立即返回. 兜底 1s 后强 break (DispatchQueue 异步).
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            buf = (try? stdin.readToEnd()) ?? Data()
            group.leave()
        }
        let timeout: DispatchTime = .now() + .milliseconds(1000)
        if group.wait(timeout: timeout) == .timedOut {
            // 父进程没及时 close write 端 — 当作明文 VM 处理 (容错)
            return nil
        }
        let trimmed = String(data: buf, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
        _ = deadline    // suppress warning
    }()

    HVMHostEntry.run(bundlePath: args[2], password: password, embeddedInGUI: embeddedInGUI)
} else {
    // GUI 模式: AppKit NSApplication runloop
    HVMAppLauncher.run()
}
