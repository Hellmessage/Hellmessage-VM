// HVMQemu/QgaExec.swift
// qemu-guest-agent (qga) 协议封装 — 通过 unix socket 在 guest 内跑 process 拿结果.
// 协议参考: https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html
//
// 用途: hvm-dbg exec --via-qga 跑 PowerShell / cmd, 拿 stdout/stderr/exit_code — 不依赖
// keyboard typing / OCR / GUI mouse, 端到端验证 guest 行为最可靠通路.
// socket / NDJSON 通路在 QgaSocket.swift (与 QgaFile 共用). 配套: guest 内 qemu-ga 服务 +
// argv 挂 chardev qga (QemuArgsBuilder 的 qgaSocketPath).

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
        let conn = try QgaSocket.connect(socketPath: socketPath)
        defer { conn.close() }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))

        // 1. guest-exec — 启进程拿 pid
        let execRet = try conn.call(
            execute: "guest-exec",
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
            let statusRet = try conn.call(
                execute: "guest-exec-status",
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
