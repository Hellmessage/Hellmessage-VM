// HostLauncher.swift
// HVM.app 作为 VMHost 子进程 (--host-mode-bundle 分支) 的拉起层. CLI + GUI store 共用.
// docs/ARCHITECTURE.md 设计: HVM executable 自带 host 分派
//
// HVM binary 探测顺序 (locateHVMBinary):
//   1. HVM_APP_PATH env (CI / 显式覆盖)
//   2. 跟随调用方自身位置 — "用我同包/同目录的 HVM", 不被 /Applications 旧版污染:
//      - 装进 .app: 调用方 (hvm-cli / GUI 的 HVM) 在 Contents/MacOS/, 兄弟即 Contents/MacOS/HVM
//      - dev build:  hvm-cli 在 build/hvm-cli, 兄弟 .app 是 build/HVM.app (无需 make install)
//   3. /Applications/HVM.app, ~/Applications/HVM.app (兜底)
// 设计稿 docs/v4/NEW_GUI_MAIN_LAYOUT.md (M1): dev 期 hvm-cli/GUI 自动用 build/HVM.app,
// 避免误用 /Applications 下的旧版 (两者 QEMU 资源可能不同步).

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

        // 2. 跟随调用方 (hvm-cli / GUI 的 HVM) 自身位置. 优先于 /Applications, 保证
        //    "我从哪个 build 出来, 就用哪个 build 的 HVM + 包内 QEMU".
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            // 装进 .app: 兄弟二进制就是 HVM (Contents/MacOS/HVM); 也覆盖 GUI 自启 host 子进程
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

    /// 拉起 VMHost 子进程并立即返回. 日志开 → stdout/stderr 重定向到全局
    /// `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/host-<date>.log`;
    /// 日志关 → stdout/stderr 重定向 /dev/null, 不创建 vmLogsDir 子目录.
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
            // (加密 VM 恒 qemu-perfile — vz-sparsebundle 已随 VZ 移除)
        } else {
            // 明文 VM: BundleIO.load (一次, 仅取 displayName + id)
            let config = try BundleIO.load(from: resolved)
            displayName = config.displayName
            vmId = config.id
            // (engine 恒 .qemu — VZ 后端已移除, Engine 单 case)
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
        _ = scheme   // QEMU-only: 恒 qemu-perfile
        let url = RoutingJSON.locationForQemuBundle(bundleURL)
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
