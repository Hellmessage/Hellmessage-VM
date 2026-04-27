// HVM/UI/App/VmnetSetupHelper.swift
// GUI 创建向导选 bridged/shared 时, 引导用户跑 install-vmnet-helper.sh + 列接口.
// 三件事:
//   1. daemonReady(mode): 检测对应 socket_vmnet daemon 是否在跑 (固定 socket 存在性)
//   2. listInterfaces(): getifaddrs 列出 IFF_UP 的接口 (en0, en1, ...) 给 bridged picker 选
//   3. runInstallScript(args:): 优先 osascript tell Terminal 跑 sudo bash <script> <args>,
//      失败 fallback 返回命令字符串供 dialog 复制
//
// install 脚本路径查找顺序:
//   a) Bundle.main.resourcePath/scripts/install-vmnet-helper.sh (打包后)
//   b) <executablePath>/../../../scripts/install-vmnet-helper.sh (dev 模式)
// 找不到时返回错误信息 (可能 .app 没正确打包)

import AppKit
import Darwin
import Foundation

@MainActor
public enum VmnetSetupHelper {

    // MARK: - daemon 就绪检测

    /// 网络模式 (与 NetworkMode 对齐, 但不依赖 HVMBundle 这边只关心 socket 路径)
    public enum DaemonMode: Sendable, Hashable {
        case shared
        case host
        case bridged(interface: String)

        var socketPath: String {
            switch self {
            case .shared:                return "/var/run/socket_vmnet"
            case .host:                  return "/var/run/socket_vmnet.host"
            case .bridged(let iface):    return "/var/run/socket_vmnet.bridged.\(iface)"
            }
        }
    }

    /// 是否对应 daemon socket 已就绪 (文件存在且为 unix socket).
    /// daemon 由 scripts/install-vmnet-helper.sh 通过 launchd 拉起 (一次性 sudo).
    public static func daemonReady(_ mode: DaemonMode) -> Bool {
        var st = stat()
        guard stat(mode.socketPath, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    // MARK: - 网络接口枚举

    public struct InterfaceInfo: Hashable, Sendable {
        public let name: String           // en0, en1, ...
        public let displayName: String    // "en0 (Wi-Fi 192.168.1.10)"
    }

    /// getifaddrs 列出所有 IFF_UP & IFF_RUNNING 的接口 (排掉 lo0 / utun / awdl 等内部).
    /// 给 bridged Picker 用. 每次调用都 fresh 探测, 不缓存 (用户可能新插网线).
    public static func listInterfaces() -> [InterfaceInfo] {
        var results: [InterfaceInfo] = []
        var seen = Set<String>()

        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var ipv4ByName: [String: String] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            let flags = Int32(cur.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            if isUp,
               let sa = cur.pointee.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET) {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let salen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(sa, salen, &hostBuf, socklen_t(NI_MAXHOST),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    // CChar (Int8) → UInt8 + 截首个 null. 用 String(bytes:encoding:) 经典 API
                    // 避免 String(cString:) (deprecated) 与 String(validating:as:) (macOS 15+)
                    let utf8 = hostBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    if let s = String(bytes: utf8, encoding: .utf8) {
                        ipv4ByName[name] = s
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }

        ptr = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            let flags = Int32(cur.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            // 过滤掉 loopback / Apple 内部 / VPN 隧道; 只留物理 + Wi-Fi
            let isExcluded = name == "lo0" ||
                name.hasPrefix("utun") ||
                name.hasPrefix("awdl") ||
                name.hasPrefix("llw") ||
                name.hasPrefix("anpi") ||
                name.hasPrefix("ap1") ||
                name.hasPrefix("bridge") ||
                name.hasPrefix("gif") ||
                name.hasPrefix("stf")

            if isUp && !isExcluded && !seen.contains(name) {
                seen.insert(name)
                let display: String
                if let ip = ipv4ByName[name] {
                    display = "\(name) (\(ip))"
                } else {
                    display = name
                }
                results.append(InterfaceInfo(name: name, displayName: display))
            }
            ptr = cur.pointee.ifa_next
        }
        return results.sorted { $0.name < $1.name }
    }

    // MARK: - install-vmnet-helper.sh 执行

    /// 定位 install-vmnet-helper.sh; nil 表示找不到.
    /// 严格只走 .app 包内副本 (Bundle.main/Resources/scripts/), 不再 fallback 到仓库 scripts/ —
    /// 因为 daemon plist 路径写死后必须长期有效, 不接受指向 dev 期临时位置 (CLAUDE.md 第三方二进制约束).
    public static func locateInstallScript() -> URL? {
        guard let resPath = Bundle.main.resourcePath else { return nil }
        let bundled = URL(fileURLWithPath: resPath)
            .appendingPathComponent("scripts/install-vmnet-helper.sh")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    public enum LaunchOutcome: Equatable, Sendable {
        case launched                              // osascript 拉起 Terminal 成功
        case fallbackCommand(command: String)      // osascript 失败 / 没找到; 返回命令供 dialog 显示
        case scriptMissing                         // 脚本完全找不到
    }

    /// 优先用 osascript 让 Terminal 跑 sudo bash <script> [extraArgs...].
    /// extraArgs 按 bridged 接口名传 (e.g. ["en0"]); 不带 extra 则装 shared+host.
    /// 失败 (Automation 权限被拒 / Terminal 不存在 / osascript 出错) 退回 fallbackCommand.
    public static func runInstallScript(extraArgs: [String] = []) -> LaunchOutcome {
        guard let script = locateInstallScript() else { return .scriptMissing }
        var cmdString = "sudo bash \"\(script.path)\""
        for a in extraArgs {
            // 严格白名单: 接口名只允许 [a-zA-Z0-9]+ (与脚本同正则), 防 shell 注入
            let allowed = a.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
            guard !a.isEmpty, allowed else { continue }
            cmdString += " \(a)"
        }

        // osascript: tell Terminal to do script
        let appleScript = "tell application \"Terminal\" to do script \"\(cmdString)\"\n" +
                          "tell application \"Terminal\" to activate"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        let pipe = Pipe()
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return .launched }
        } catch {
            // 可能 osascript 不存在 (极罕见) 或路径问题; 走 fallback
        }
        return .fallbackCommand(command: cmdString)
    }

    /// 把命令字符串拷到剪贴板, 给 fallback dialog 的「复制」按钮用
    public static func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// 校验 launchd label 安全字符集 (防 osascript / shell 注入).
    /// launchd 官方 Label 字符规范是 [a-zA-Z0-9._-]+, 我们强制走这个白名单.
    private static func isSafeLabel(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        return label.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    /// 校验绝对路径 (用于 plist + socket 路径), 严格白名单防 shell 注入.
    /// 允许字符: [a-zA-Z0-9./_-], 必须以 / 开头.
    private static func isSafeAbsPath(_ p: String) -> Bool {
        guard p.hasPrefix("/") else { return false }
        return p.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/.-_".unicodeScalars.contains($0)
        }
    }

    /// 通过 osascript 拉 Terminal 跑 sudo launchctl kickstart -k system/<label>,
    /// 用于"daemon plist 装了但 socket file 缺"(僵尸) 的场景一键修复.
    /// label 必须在白名单字符集内 (防 osascript 注入); 不允许引号/分号/反斜杠等
    public static func kickstartDaemon(label: String) -> LaunchOutcome {
        guard isSafeLabel(label) else {
            return .fallbackCommand(command: "sudo launchctl kickstart -k system/<INVALID-LABEL>")
        }
        let cmd = "sudo launchctl kickstart -k system/\(label)"

        let appleScript = "tell application \"Terminal\" to do script \"\(cmd)\"\n" +
                          "tell application \"Terminal\" to activate"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return .launched }
        } catch {
            // osascript 不可用 → fallback
        }
        return .fallbackCommand(command: cmd)
    }

    /// 通过 osascript 拉 Terminal 卸载指定 daemon: bootout + rm plist + rm socket.
    /// 跨项目通用: 不只限 HVM 自己装的 (com.hellmessage.hvm.vmnet.*), 也能卸 lima /
    /// hell-vm 等共存项目装的. 由 popover 行内"卸载"按钮触发, 用户已在 UI 上显式选择
    /// 要卸哪个 daemon, 故跨项目也属合理用户意图 (而非 install 阶段的"自动抢").
    /// label / plistPath / socketPath 都过白名单校验, 防 osascript 注入.
    public static func uninstallDaemon(label: String, plistPath: String, socketPath: String) -> LaunchOutcome {
        guard isSafeLabel(label),
              isSafeAbsPath(plistPath),
              isSafeAbsPath(socketPath) else {
            return .fallbackCommand(command: "sudo launchctl bootout system/<INVALID>")
        }
        // 三步串成 single sudo 调用, 避免每步都弹密码 prompt
        let cmd = "sudo bash -c " +
            "'launchctl bootout system/\(label) 2>/dev/null; " +
            "rm -f \"\(plistPath)\" \"\(socketPath)\"'"

        let appleScript = "tell application \"Terminal\" to do script \"\(cmd)\"\n" +
                          "tell application \"Terminal\" to activate"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return .launched }
        } catch {
            // osascript 不可用 → fallback 复制命令
        }
        return .fallbackCommand(command: cmd)
    }
}
