// HostLauncher.swift
// hvm-cli 拉起 HVM.app 作为 VMHost 子进程 (--host-mode-bundle 分支)
// docs/ARCHITECTURE.md 设计: HVM executable 自带 host 分派
//
// 严格只查 .app 安装位置 (CLAUDE.md 第三方二进制约束):
//   1. HVM_APP_PATH env (CI / 调试)
//   2. /Applications/HVM.app
//   3. ~/Applications/HVM.app
// 不再 fallback 到 build/HVM.app — dev 期 hvm-cli start 前需先 make install.

import Foundation
import HVMBundle
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

        // 2. 标准安装路径
        for sys in ["/Applications/HVM.app", "\(NSHomeDirectory())/Applications/HVM.app"] {
            let u = URL(fileURLWithPath: sys).appendingPathComponent("Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: u.path) { return u }
        }

        return nil
    }

    /// 拉起 VMHost 子进程并立即返回. stdout/stderr 重定向到全局
    /// `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/host-<date>.log`.
    /// 返回子进程 pid
    @discardableResult
    public static func launch(bundleURL: URL) throws -> Int32 {
        guard let binary = locateHVMBinary() else {
            throw HVMError.backend(.vzInternal(
                description: "未找到 HVM.app (仅查 /Applications/HVM.app 与 ~/Applications/HVM.app); 请 make install 或设置 $HVM_APP_PATH"
            ))
        }

        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        // 取 config 拿 displayName + id 用于全局 log 子目录命名
        let config = try BundleIO.load(from: resolved)
        let logURL = try makeHostLogURL(displayName: config.displayName, id: config.id)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--host-mode-bundle", resolved.path]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // 将子进程放到独立进程组, 确保 hvm-cli 退出后它不被信号连坐
        // Swift Process 默认已是新 pgid, 这里保险起见不做额外处理

        try proc.run()
        return proc.processIdentifier
    }

    /// 计算并准备 host-<date>.log 路径 (全局 logs 子目录, 不在 bundle 内).
    /// 公开给 GUI 侧 (AppModel.spawnExternalHost) 共用, 保两边路径完全一致.
    public static func makeHostLogURL(displayName: String, id: UUID) throws -> URL {
        let dir = HVMPaths.vmLogsDir(displayName: displayName, id: id)
        try HVMPaths.ensure(dir)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("host-\(df.string(from: Date())).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
