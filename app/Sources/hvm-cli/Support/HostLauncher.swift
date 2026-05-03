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
import HVMEncryption

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
    ///
    /// 加密 VM (`password` 非空) 通过 stdin Pipe 透传 password 到子进程, 子进程
    /// main.swift 读 stdin until EOF, 拿到 password 后调 EncryptedBundleIO.unlock.
    /// 明文 VM (`password` nil) 走原路径, stdin 立即 close (子进程读到 EOF, 当作明文).
    ///
    /// 返回子进程 pid
    @discardableResult
    public static func launch(bundleURL: URL, password: String? = nil) throws -> Int32 {
        guard let binary = locateHVMBinary() else {
            throw HVMError.backend(.vzInternal(
                description: "未找到 HVM.app (仅查 /Applications/HVM.app 与 ~/Applications/HVM.app); 请 make install 或设置 $HVM_APP_PATH"
            ))
        }

        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL

        // displayName + id 用于全局 log 子目录命名. 加密 VM 走 EncryptedBundleIO.detectScheme
        // 不解密拿 routing JSON 里的 displayName + 走 BundleDiscovery 的 fallback (沿用现状对明文).
        let displayName: String
        let vmId: UUID
        if let scheme = EncryptedBundleIO.detectScheme(at: resolved),
           let routing = readRouting(at: resolved, scheme: scheme) {
            displayName = routing.displayName
            vmId = routing.vmId
        } else {
            // 明文 VM: BundleIO.load (一次, 仅取 displayName + id)
            let config = try BundleIO.load(from: resolved)
            displayName = config.displayName
            vmId = config.id
        }
        let logURL = try makeHostLogURL(displayName: displayName, id: vmId)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--host-mode-bundle", resolved.path]
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // stdin: 透传 password (加密 VM) / 立即 close (明文 VM)
        let stdinPipe = Pipe()
        proc.standardInput = stdinPipe

        try proc.run()

        // 启动后立即写 password + close write 端 (子进程读 EOF 即拿到 password)
        if let pw = password, !pw.isEmpty {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(pw.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()

        return proc.processIdentifier
    }

    /// 读 routing JSON (不解密) 拿 displayName + vmId. 失败返 nil.
    private static func readRouting(at bundleURL: URL,
                                     scheme: EncryptionSpec.EncryptionScheme) -> RoutingMetadata? {
        let url: URL
        switch scheme {
        case .vzSparsebundle: url = RoutingJSON.locationForSparsebundle(bundleURL)
        case .qemuPerfile:    url = RoutingJSON.locationForQemuBundle(bundleURL)
        }
        return try? RoutingJSON.read(from: url)
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
