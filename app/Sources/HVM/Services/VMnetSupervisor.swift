// HVM/Services/VMnetSupervisor.swift
// socket_vmnet daemon 的生命周期代理 (新方案, hell-vm 同款).
//
// 职责:
//   - 装 / 卸 / 列 socket_vmnet 系统级 launchd daemon
//   - 提供 daemon 当前 socket 就绪状态给 UI 展示
//
// 提权方式: osascript "do shell script ... with administrator privileges" 弹原生
// Touch ID / 密码框 (hell-vm 同款). 不写 sudoers, 不拉 Terminal, 不用 NOPASSWD.
//
// 安装脚本: scripts/install-vmnet-daemons.sh, 由 bundle.sh 拷入 .app/Resources/scripts/.
// 脚本从 brew 路径找 socket_vmnet (`/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet`),
// 写 launchd plist `/Library/LaunchDaemons/com.hellmessage.hvm.vmnet.<mode>.plist`.
// daemon socket 路径走 SocketPaths.* (跟 socket_vmnet 上游 / lima / hell-vm 一致).

import Foundation
import HVMCore

@MainActor
public enum VMnetSupervisor {

    private static let log = HVMLog.logger("VMnetSupervisor")

    // MARK: - 状态查询

    /// 当前系统上已就绪的 vmnet socket 一览, 给 "网络诊断" 面板展示.
    public static func presentSockets() -> (shared: Bool, host: Bool, bridged: [String]) {
        let fm = FileManager.default
        let shared = SocketPaths.isReady(SocketPaths.vmnetShared)
        let host   = SocketPaths.isReady(SocketPaths.vmnetHost)
        // bridged.<iface> 扫一遍 /var/run
        var bridged: [String] = []
        let runURL = URL(fileURLWithPath: "/var/run")
        if let items = try? fm.contentsOfDirectory(atPath: runURL.path) {
            let prefix = (SocketPaths.vmnetBase as NSString).lastPathComponent + ".bridged."
            for name in items where name.hasPrefix(prefix) {
                bridged.append(String(name.dropFirst(prefix.count)))
            }
        }
        return (shared, host, bridged.sorted())
    }

    // MARK: - 安装 / 卸载

    /// 安装 shared + host + N 个 bridged.<iface> daemon (任一 vmnet socket 缺失时调).
    /// 一次 osascript 弹 Touch ID / 密码授权框, 一次到位. 用户拒绝时 throw userCancelled.
    public static func installAllDaemons(extraBridgedInterfaces: [String] = []) async throws {
        let script = try scriptPath()
        var bridged = Set<String>()
        for iface in extraBridgedInterfaces where !iface.isEmpty {
            bridged.insert(iface)
        }
        var args = [script]
        args.append(contentsOf: bridged.sorted())
        try await runWithAdminPrivileges(args: args)
    }

    /// 卸载全部 HVM 管理的 vmnet daemon (label 前缀 com.hellmessage.hvm.vmnet.*).
    public static func uninstallAllDaemons() async throws {
        let script = try scriptPath()
        try await runWithAdminPrivileges(args: [script, "--uninstall"])
    }

    // MARK: - 内部: 脚本定位 + 提权执行

    public enum VMnetError: LocalizedError {
        case scriptNotFound
        case userCancelled
        case osaFailed(String)

        public var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "找不到 install-vmnet-daemons.sh (HVM.app 资源不全, 请 make build 后 make install)"
            case .userCancelled:
                return "用户取消了授权"
            case .osaFailed(let msg):
                return "osascript 执行失败: \(msg)"
            }
        }
    }

    /// 严格只走 .app 包内 Resources/scripts/, 不再 fallback 到仓库 — daemon plist 路径写死,
    /// 必须指向 /Applications/HVM.app 这种长期稳定位置. 见 CLAUDE.md 第三方二进制约束.
    private static func scriptPath() throws -> String {
        guard let res = Bundle.main.resourcePath else { throw VMnetError.scriptNotFound }
        let bundled = URL(fileURLWithPath: res)
            .appendingPathComponent("scripts/install-vmnet-daemons.sh")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        throw VMnetError.scriptNotFound
    }

    /// 用 osascript 触发 Touch ID / 密码授权框执行 `sudo bash <script> <args>`.
    /// 参数走 AppleScript 字符串转义 (双引号 + 反斜杠).
    private static func runWithAdminPrivileges(args: [String]) async throws {
        let shellLine = args.map { shellEscape($0) }.joined(separator: " ")
        let appleScriptBody =
            "do shell script \"/bin/bash \(escapeForAppleScript(shellLine))\" with administrator privileges"

        log.info("vmnet: installing daemons via osascript")

        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments = ["-e", appleScriptBody]

            let errPipe = Pipe()
            let outPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = outPipe
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                // 用户点取消 osascript 会返回 errno -128
                if err.contains("-128") || err.lowercased().contains("user canceled") {
                    throw VMnetError.userCancelled
                }
                throw VMnetError.osaFailed(err.isEmpty ? "exit \(proc.terminationStatus)" : err)
            }
        }.value
    }

    /// 给 shell 层转义 (外层包双引号, 内部的 " 和 \\ 要加反斜杠)
    private static func shellEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + out + "\""
    }

    /// 给 AppleScript 层转义 (外层已是 do shell script "...", 内部 " 要变 \")
    private static func escapeForAppleScript(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }
}
