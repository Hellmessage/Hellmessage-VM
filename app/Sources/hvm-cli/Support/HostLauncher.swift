// HostLauncher.swift
// hvm-cli 拉起 HVM.app 作为 VMHost 子进程 (--host-mode-bundle 分支)
// docs/ARCHITECTURE.md 设计: HVM executable 自带 host 分派

import Foundation
import HVMCore

public enum HostLauncher {
    /// 探测 HVM.app 的 Mach-O binary 路径
    public static func locateHVMBinary() -> URL? {
        let fm = FileManager.default

        // 1. 环境变量
        if let override = ProcessInfo.processInfo.environment["HVM_APP_PATH"] {
            let candidate = URL(fileURLWithPath: override)
                .appendingPathComponent("Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        // 2. 相对 hvm-cli 自身 (开发期 build/ 布局; /usr/local/bin symlink 下 realpath 会解)
        let cliURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let cliReal = cliURL.resolvingSymlinksInPath()
        let dir = cliReal.deletingLastPathComponent()
        let dev = dir.appendingPathComponent("HVM.app/Contents/MacOS/HVM")
        if fm.isExecutableFile(atPath: dev.path) { return dev }

        // 3. 常见安装路径
        for sys in ["/Applications/HVM.app", "\(NSHomeDirectory())/Applications/HVM.app"] {
            let u = URL(fileURLWithPath: sys).appendingPathComponent("Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: u.path) { return u }
        }

        return nil
    }

    /// 拉起 VMHost 子进程并立即返回. stdout/stderr 重定向到 bundle/logs/host-<date>.log
    /// 返回子进程 pid
    @discardableResult
    public static func launch(bundleURL: URL) throws -> Int32 {
        guard let binary = locateHVMBinary() else {
            throw HVMError.backend(.vzInternal(
                description: "未找到 HVM.app; 请先 make build 或设置 $HVM_APP_PATH"
            ))
        }

        // 日志目标: bundle/logs/host-YYYY-MM-DD.log
        let fm = FileManager.default
        let logsDir = bundleURL.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let logURL = logsDir.appendingPathComponent("host-\(df.string(from: Date())).log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--host-mode-bundle", bundleURL.path]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // 将子进程放到独立进程组, 确保 hvm-cli 退出后它不被信号连坐
        // Swift Process 默认已是新 pgid, 这里保险起见不做额外处理

        try proc.run()
        return proc.processIdentifier
    }
}
