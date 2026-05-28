// HVMDisplayQemu/GuestHelperInstaller.swift
//
// HVM Guest Helper EXE 自动安装. 详见 docs/v3/HOST_FILE_CLIPBOARD.md §4.5.
//
// 触发时机: QemuHostEntry 在 Windows VM 启动 + QGA 就绪后调一次 install(...).
//
// 流程:
//   1. 检测 marker: QGA exec PowerShell test 'C:\ProgramData\HVM\.helper-installed-v1'
//   2. 已装 → 跳过 (idempotent, 同 marker version 多次开机不重复推 EXE)
//   3. 未装:
//      a. mkdir 'C:\HVMGuestHelper\'
//      b. QGA push hvm-guest-helper.exe → 上述目录
//      c. 写 HKLM\Software\Microsoft\Windows\CurrentVersion\Run\HVMGuestHelper REG_SZ
//      d. 写 marker (touch 'C:\ProgramData\HVM\.helper-installed-v1')
//      e. 用 schtasks /RU INTERACTIVE 跑一次性 task 立即拉起 (跑在 user session, 不等下次登录).
//         失败不算 fatal — 下次 boot 走 Run key 仍能拉起.
//
// 升级路径: marker 文件名带 version (v1, v2, ...). 改 marker 名 → 自动重装.

import Foundation
import OSLog
import HVMQemu

private let log = Logger(subsystem: "com.hellmessage.vm", category: "GuestHelperInstaller")

public enum GuestHelperInstaller {

    /// marker 文件 — 装好之后 touch 一下, 下次开机看到就跳过. 版本号在文件名里, 升级时改名.
    /// v2: 改 Run reg key → schtasks ONLOGON + /RL HIGHEST (virtio-serial 要 admin token).
    public static let markerPath = #"C:\ProgramData\HVM\.helper-installed-v2"#
    /// 老 marker 路径 — install 时一并删, 顺便清掉老的 Run reg key.
    public static let oldMarkerPaths: [String] = [
        #"C:\ProgramData\HVM\.helper-installed-v1"#,
    ]

    /// guest 端安装目录 + EXE 路径.
    public static let installDir = #"C:\HVMGuestHelper"#
    public static let installedExePath = #"C:\HVMGuestHelper\hvm-guest-helper.exe"#

    /// schtasks 持久任务名. SC ONLOGON / RL HIGHEST, 每次用户登录自动起 helper.
    /// 升级时同名直接覆盖.
    public static let persistTaskName = "HVMGuestHelper"

    public enum InstallError: Error, CustomStringConvertible {
        case exeNotFound(String)
        case qgaFailed(String)

        public var description: String {
            switch self {
            case .exeNotFound(let p): return "helper EXE not found at \(p)"
            case .qgaFailed(let r): return "QGA op failed: \(r)"
            }
        }
    }

    /// 在 HVM.app/Contents/Resources/GuestHelper/hvm-guest-helper.exe 里找 EXE.
    /// 找不到 → nil (Linux/macOS guest 不需要, 或 packaging 没拷贝).
    public static func locateBundledExe() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let exe = res.appendingPathComponent("GuestHelper/hvm-guest-helper.exe")
        return FileManager.default.fileExists(atPath: exe.path) ? exe : nil
    }

    /// 同上, libunwind.dll. Optional — 没找到时不算错 (但 helper 启不来).
    public static func locateBundledDll() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dll = res.appendingPathComponent("GuestHelper/libunwind.dll")
        return FileManager.default.fileExists(atPath: dll.path) ? dll : nil
    }

    /// 主入口. async, 总耗时数秒 (QGA push EXE ~280KB 通常 < 5s).
    /// 成功返 (installed: true) 表示这次真的装了; (installed: false) 表示 marker 已存在 skip.
    /// 失败抛 InstallError, 调用方 log warn 但不算 VM 启动失败 — helper 没装只是文件剪贴板
    /// 不可用, 其他 VM 功能正常.
    /// timeouts 给很大值: Windows guest 第一次跑 PowerShell 通常 30-60s (.NET runtime + module
    /// 加载). 第二次以后秒级.
    public static func install(qgaSocketPath: String) async throws -> (installed: Bool, message: String) {
        guard let exeURL = locateBundledExe() else {
            throw InstallError.exeNotFound("Bundle.main/Resources/GuestHelper/hvm-guest-helper.exe")
        }

        fputs("HVMHost(qemu): GuestHelper.install begin (EXE=\(exeURL.lastPathComponent))\n", stderr)

        // 0. 等 QGA 在 guest 内 ready (qemu-ga.exe Windows service 通常 boot 后 30-60s
        //    才起来; 在那之前 QGA chardev socket 是 QEMU listening 但 guest 没 client,
        //    任何 guest-exec 都 timeout). 用一个 cheap ping 探测 + 指数退避重试, 最多 10 min.
        fputs("HVMHost(qemu): GuestHelper step 0/6 等 QGA 在 guest 端就绪 (qemu-ga service)\n", stderr)
        try await waitForQgaReady(qgaSocketPath: qgaSocketPath, totalTimeoutSec: 600)

        // 1. 检测 marker. 顺便清老 v1 marker + 老 Run reg key (v1→v2 升级路径).
        fputs("HVMHost(qemu): GuestHelper step 1/6 markerExists\n", stderr)
        if try await markerExists(qgaSocketPath: qgaSocketPath) {
            return (false, "已装 (marker 存在), 跳过")
        }
        fputs("HVMHost(qemu): GuestHelper marker 不存在, 开始安装 (顺便清老版本)\n", stderr)
        // 清老 marker + Run reg key + 老 helper 进程 + 老安装目录 (Program Files 那个).
        // 失败不抛 — 老版本可能根本没装过.
        let cleanupOld = """
            Stop-Process -Name hvm-guest-helper -Force -ErrorAction SilentlyContinue
            reg delete 'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' /v HVMGuestHelper /f 2>$null | Out-Null
            Remove-Item 'C:\\Program Files\\HVM Guest Helper' -Recurse -Force -ErrorAction SilentlyContinue
            \(oldMarkerPaths.map { #"Remove-Item '\#($0)' -Force -ErrorAction SilentlyContinue"# }.joined(separator: "\n"))
            """
        try? await runPowerShell(
            qgaSocketPath: qgaSocketPath,
            script: cleanupOld,
            timeoutSec: 30,
            errorTag: "cleanup old"
        )

        // 2. mkdir install dir
        fputs("HVMHost(qemu): GuestHelper step 2/6 mkdir install dir\n", stderr)
        try await runPowerShell(
            qgaSocketPath: qgaSocketPath,
            script: #"New-Item -ItemType Directory -Force -Path '\#(installDir)' | Out-Null"#,
            timeoutSec: 120,
            errorTag: "mkdir install dir"
        )

        // 3. QGA push EXE (+ libunwind.dll if 存在 — helper 用 llvm-mingw 链 LLVM unwinder,
        //    不带 DLL Windows loader 直接静默 abort)
        fputs("HVMHost(qemu): GuestHelper step 3/6 push EXE + DLL\n", stderr)
        let pushStart = Date()
        do {
            _ = try await QgaFile.push(
                socketPath: qgaSocketPath,
                srcLocal: exeURL,
                dstRemote: installedExePath,
                timeoutSec: 120,
                progress: nil
            )
            if let dllURL = locateBundledDll() {
                let dllPath = #"\#(installDir)\libunwind.dll"#
                _ = try await QgaFile.push(
                    socketPath: qgaSocketPath,
                    srcLocal: dllURL,
                    dstRemote: dllPath,
                    timeoutSec: 60,
                    progress: nil
                )
            } else {
                fputs("HVMHost(qemu): ⚠ GuestHelper libunwind.dll 没找到, helper 可能起不来\n", stderr)
            }
        } catch {
            throw InstallError.qgaFailed("QGA push hvm-guest-helper.exe / libunwind.dll: \(error)")
        }
        let pushMs = Int(Date().timeIntervalSince(pushStart) * 1000)
        fputs("HVMHost(qemu): GuestHelper push ok (\(pushMs) ms, EXE+DLL)\n", stderr)

        // 4. 注册持久 schtasks ONLOGON 任务 (取代 Run reg key).
        //    必须 /RL HIGHEST: virtio-serial port ACL 拒普通 user, 需要 admin token.
        //    /SC ONLOGON: 每个用户登录自动起一份 helper (跑在该用户 session).
        fputs("HVMHost(qemu): GuestHelper step 4/6 schtasks ONLOGON 任务\n", stderr)
        let createPersist = #"schtasks /create /TN \#(persistTaskName) /TR '\#(installedExePath)' /SC ONLOGON /RU INTERACTIVE /RL HIGHEST /F | Out-Null"#
        try await runPowerShell(
            qgaSocketPath: qgaSocketPath,
            script: createPersist,
            timeoutSec: 60,
            errorTag: "schtasks ONLOGON 持久任务"
        )

        // 5. 写 marker — 标记装好了, 下次开机跳过
        fputs("HVMHost(qemu): GuestHelper step 5/6 write marker\n", stderr)
        try await runPowerShell(
            qgaSocketPath: qgaSocketPath,
            script: #"New-Item -ItemType File -Force -Path '\#(markerPath)' | Out-Null"#,
            timeoutSec: 60,
            errorTag: "write marker"
        )

        // 6. 立即拉起 (one-shot schtasks /RU INTERACTIVE). 失败不算 fatal.
        fputs("HVMHost(qemu): GuestHelper step 6/6 schtasks immediate run\n", stderr)
        do {
            try await launchInUserSession(qgaSocketPath: qgaSocketPath)
            return (true, "已装 + 已拉起 (immediate)")
        } catch {
            fputs("HVMHost(qemu): GuestHelper schtasks failed (will start on next user login): \(error)\n", stderr)
            return (true, "已装 (helper 将在下次 user 登录时自动启动: \(error))")
        }
    }

    /// 立即拉起 helper. step 4 已注册 ONLOGON 持久任务, 这里直接 /run 触发一次 (next logon
    /// 会按 SC ONLOGON 触发器自动重起, 不需要这里维护).
    /// 失败不抛 — 调用方知道 fallback 是 "下次登录 ONLOGON 自动起".
    private static func launchInUserSession(qgaSocketPath: String) async throws {
        let runPersist = #"schtasks /run /TN \#(persistTaskName) | Out-Null"#
        try await runPowerShell(
            qgaSocketPath: qgaSocketPath,
            script: runPersist,
            timeoutSec: 30,
            errorTag: "schtasks /run ONLOGON 任务"
        )
    }

    /// 探测 QGA 在 guest 内是否 ready (qemu-ga.exe service 起来 + 接到 chardev). 跑廉价
    /// PowerShell `1` 命令, 成功就当 ready. 每 5s 试一次, 总超时 totalTimeoutSec.
    /// 失败抛 InstallError.qgaFailed.
    private static func waitForQgaReady(qgaSocketPath: String, totalTimeoutSec: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(totalTimeoutSec))
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            do {
                _ = try await QgaExec.run(
                    socketPath: qgaSocketPath,
                    path: "powershell.exe",
                    args: ["-NoProfile", "-NonInteractive", "-Command", "1"],
                    timeoutSec: 10
                )
                fputs("HVMHost(qemu): GuestHelper QGA ready (attempt \(attempt))\n", stderr)
                return
            } catch {
                // 还没 ready, 5s 后重试
                if attempt % 6 == 1 {  // 每 30s 打一次, 不刷屏
                    fputs("HVMHost(qemu): GuestHelper QGA 还没 ready (attempt \(attempt)), 5s 后重试\n", stderr)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        throw InstallError.qgaFailed("等 QGA ready 超时 \(totalTimeoutSec)s (Windows guest qemu-ga service 没起来? 检查 UTM Guest Tools 装了没)")
    }

    private static func markerExists(qgaSocketPath: String) async throws -> Bool {
        let script = #"if (Test-Path '\#(markerPath)') { 'yes' } else { 'no' }"#
        let result = try await runPowerShellCapturing(
            qgaSocketPath: qgaSocketPath, script: script, timeoutSec: 120
        )
        return result.stdout.contains("yes")
    }

    // MARK: - QGA exec helpers

    private static func runPowerShell(
        qgaSocketPath: String, script: String, timeoutSec: Int, errorTag: String
    ) async throws {
        let r = try await QgaExec.run(
            socketPath: qgaSocketPath,
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", script],
            timeoutSec: timeoutSec
        )
        if r.exitCode != 0 {
            let stderr = Data(base64Encoded: r.stderrBase64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw InstallError.qgaFailed("\(errorTag) exit=\(r.exitCode): \(stderr.prefix(200))")
        }
    }

    private static func runPowerShellCapturing(
        qgaSocketPath: String, script: String, timeoutSec: Int
    ) async throws -> (stdout: String, exitCode: Int) {
        let r = try await QgaExec.run(
            socketPath: qgaSocketPath,
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", script],
            timeoutSec: timeoutSec
        )
        let stdout = Data(base64Encoded: r.stdoutBase64).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (stdout, r.exitCode)
    }
}
