// HostLauncher.swift
// 拉起 HVM.app 作 VMHost 子进程 (--host-mode-bundle). CLI + GUI store 共用.
//
// HVM binary 探测顺序 (locateHVMBinary): 详见函数内注释.
// 核心: 优先"跟随调用方自身位置", 避免误用 /Applications 旧版 (QEMU 资源可能不同步).

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

public enum HostLauncher {
    /// 探测 HVM.app 的 Mach-O binary 路径
    public static func locateHVMBinary() -> URL? {
        let fm = FileManager.default

        // 1. 显式 env override
        if let override = ProcessInfo.processInfo.environment["HVM_APP_PATH"] {
            let candidate = URL(fileURLWithPath: override)
                .appendingPathComponent("Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        // 2. 跟随调用方自身位置 (优先于 /Applications): 从哪个 build 出来就用哪个 build 的 HVM + 包内 QEMU
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            // 装进 .app: 兄弟即 Contents/MacOS/HVM
            let siblingBinary = dir.appendingPathComponent("HVM")
            if fm.isExecutableFile(atPath: siblingBinary.path) { return siblingBinary }
            // dev build: build/hvm-cli 兄弟 .app 是 build/HVM.app
            let siblingApp = dir.appendingPathComponent("HVM.app/Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: siblingApp.path) { return siblingApp }
        }

        // 3. 标准安装路径 (兜底)
        for sys in ["/Applications/HVM.app", "\(NSHomeDirectory())/Applications/HVM.app"] {
            let u = URL(fileURLWithPath: sys).appendingPathComponent("Contents/MacOS/HVM")
            if fm.isExecutableFile(atPath: u.path) { return u }
        }

        return nil
    }

    /// 拉起 VMHost 子进程并立即返回子进程 pid. 日志开 → stdout/stderr 重定向到全局 host-<date>.log, 关 → /dev/null.
    /// 加密 VM (`password` 非空) 通过 stdin Pipe 透传 password; 明文 (nil) 立即 close stdin (子进程读 EOF 当明文).
    @discardableResult
    public static func launch(bundleURL: URL, password: String? = nil) throws -> Int32 {
        guard let binary = locateHVMBinary() else {
            throw HVMError.backend(.vzInternal(
                description: "未找到 HVM.app (仅查 /Applications/HVM.app 与 ~/Applications/HVM.app); 请 make install 或设置 $HVM_APP_PATH"
            ))
        }

        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL

        // displayName + id 用于全局 log 子目录命名. 加密 VM 不解密走 routing JSON, 明文走 BundleIO.load.
        let displayName: String
        let vmId: UUID
        if let scheme = EncryptedBundleIO.detectScheme(at: resolved),
           let routing = readRouting(at: resolved, scheme: scheme) {
            displayName = routing.displayName
            vmId = routing.vmId
        } else {
            let config = try BundleIO.load(from: resolved)
            displayName = config.displayName
            vmId = config.id
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--host-mode-bundle", resolved.path]
        if LoggingPreferences.readEnabledFromDefaults() {
            let logURL = try makeHostLogURL(displayName: displayName, id: vmId)
            let logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle.seekToEnd()
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        } else {
            let devNull = FileHandle(forWritingAtPath: "/dev/null")
            proc.standardOutput = devNull
            proc.standardError = devNull
        }
        let stdinPipe = Pipe()
        proc.standardInput = stdinPipe

        try proc.run()

        // 写 password + close write 端 (子进程读 EOF 即拿到)
        if let pw = password, !pw.isEmpty {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(pw.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()

        return proc.processIdentifier
    }

    /// 读 routing JSON (不解密) 拿 displayName + vmId. 失败返 nil.
    private static func readRouting(at bundleURL: URL,
                                     scheme: EncryptionSpec.EncryptionScheme) -> RoutingMetadata? {
        _ = scheme   // 恒 qemu-perfile
        let url = RoutingJSON.locationForQemuBundle(bundleURL)
        return try? RoutingJSON.read(from: url)
    }

    /// 准备 host-<date>.log 路径 (全局 logs 子目录, 不在 bundle 内). 公开给 GUI 侧共用保路径一致.
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
