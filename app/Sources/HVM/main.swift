// HVM executable 主入口: 按 argv 分派 GUI 模式或 VMHost 模式.

import Foundation
import HVMCore

// SIGPIPE 忽略必须在任何 IPC 监听 / 子进程派生之前. 覆盖 GUI 主进程 + host 子进程.
SignalGuard.ignoreSIGPIPE()

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--host-mode-bundle" {
    // VMHost 模式: 接管指定 bundle, 启动 VM, 监听 IPC socket.
    // --gui-embedded: GUI 主进程派生时传入, host 子进程跳过自己的 status item 避免重复图标.
    let embeddedInGUI = args.dropFirst(3).contains("--gui-embedded")

    // 加密 VM password 经 stdin 透传: 父进程 write + close write 端, 子进程 read until EOF
    // (1s timeout 防阻塞). 空内容 = 明文 VM, 非空 = 加密 VM 密码.
    let password: String? = {
        let stdin = FileHandle.standardInput
        // NSLock 包 buf 避 Sendable 警告 (closure 跑独立线程, buf 主线程读)
        let lock = NSLock()
        nonisolated(unsafe) var buf = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let read = (try? stdin.readToEnd()) ?? Data()
            lock.lock(); buf = read; lock.unlock()
            group.leave()
        }
        let timeout: DispatchTime = .now() + .milliseconds(1000)
        if group.wait(timeout: timeout) == .timedOut {
            // 父进程没及时 close write 端 — 当明文 VM 处理 (容错)
            return nil
        }
        lock.lock(); let snapshot = buf; lock.unlock()
        let trimmed = String(data: snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }()

    HVMHostEntry.run(bundlePath: args[2], password: password, embeddedInGUI: embeddedInGUI)
} else {
    // GUI 模式: AppKit NSApplication runloop, 走 GUI/** 下的 NewGUIAppLauncher.
    NewGUIAppLauncher.run()
}
