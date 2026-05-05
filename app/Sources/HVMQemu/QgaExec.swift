// HVMQemu/QgaExec.swift
//
// qemu-guest-agent (qga) 协议封装 — 通过 unix socket 在 guest 内跑 process 拿结果.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// 用途: hvm-dbg exec --via-qga 跑 PowerShell / cmd 等命令, 拿 stdout/stderr/exit_code.
// 不依赖 keyboard typing (避 IME 字符替换) / OCR (避识别误差) / GUI mouse (避 USB
// tablet 坐标问题) — 端到端自动化验证 guest 行为最可靠通路.
//
// socket / NDJSON 通路在 QgaSocket.swift, 与 QgaFile.swift 共用.
//
// 配套要求:
//   - argv 挂 chardev qga + virtserialport name=org.qemu.guest_agent.0 (QemuArgsBuilder
//     已支持 qgaSocketPath)
//   - guest 内装 qemu-ga.exe 服务 (UTM Guest Tools 装包含 qemu-ga-x86_64.msi)
//   - 服务自动连 \\.\Global\com.qemu.guest_agent.0 virtio-serial port

import Foundation
import Darwin

public enum QgaExec {

    public struct Result: Sendable {
        public let exitCode: Int
        public let stdoutBase64: String
        public let stderrBase64: String
    }

    /// 跑 guest 内 process. 阻塞直到 process exit / 超时.
    /// path: binary 全路径 (e.g. "powershell.exe", "C:\\Windows\\System32\\cmd.exe")
    /// args: argv (path 之后的参数)
    /// timeoutSec: 整体超时, 含 launch + wait exit
    public static func run(
        socketPath: String, path: String, args: [String], timeoutSec: Int = 30
    ) async throws -> Result {
        let fd = try QgaSocket.connectUnix(socketPath: socketPath)
        defer { Darwin.close(fd) }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        // 1. guest-exec — 启进程拿 pid
        let execRet = try QgaSocket.call(
            fd: fd, execute: "guest-exec",
            arguments: [
                "path": path,
                "arg": args,
                "capture-output": true,
            ],
            deadline: Date().addingTimeInterval(5)
        )
        guard let returnDict = execRet as? [String: Any],
              let pid = returnDict["pid"] as? Int else {
            throw QgaError.execStartFailed(reason: "guest-exec response missing pid: \(execRet)")
        }

        // 2. 轮询 guest-exec-status 直到 exited
        var pollInterval: useconds_t = 100_000  // 100ms
        let maxPollInterval: useconds_t = 1_000_000  // 1s
        while Date() < deadline {
            usleep(pollInterval)
            pollInterval = min(maxPollInterval, pollInterval * 2)
            let statusRet = try QgaSocket.call(
                fd: fd, execute: "guest-exec-status",
                arguments: ["pid": pid],
                deadline: deadline
            )
            guard let ret = statusRet as? [String: Any] else { continue }
            let exited = (ret["exited"] as? Bool) ?? false
            if exited {
                let exitcode = (ret["exitcode"] as? Int) ?? -1
                let stdoutB64 = (ret["out-data"] as? String) ?? ""
                let stderrB64 = (ret["err-data"] as? String) ?? ""
                return Result(exitCode: exitcode, stdoutBase64: stdoutB64, stderrBase64: stderrB64)
            }
        }
        throw QgaError.timeout
    }
}
