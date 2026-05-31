// hvm-dbg helper-exec — 通过 HVM guest helper RPC 在 guest【登录用户会话】跑命令.
//
// 与 `hvm-dbg exec-guest` 的关键区别:
//   - exec-guest 走 qemu-guest-agent (qemu-ga.exe), 跑在 SYSTEM 会话 0 (非交互桌面)
//   - helper-exec 走 HVM 自家 helper (schtasks ONLOGON /RU INTERACTIVE), 跑在登录用户会话 1
// 用于诊断 / 操作只在 user session 可见的状态: 剪贴板 (CF_HDROP) / window station / 用户环境变量.
//
// 安全 (见 docs/GUEST_HELPER_RPC_DESIGN.md §5b): host 是发命令的权威方, guest 返回的 stdout/stderr
// 一律当惰性 bytes — 这里只 base64 解码后打印, 不在 host eval / 拼命令 / 喂 Process.
//
// 用法:
//   hvm-dbg helper-exec <vm> --ps 'Get-Date'
//   hvm-dbg helper-exec <vm> --cmd 'whoami'
//   hvm-dbg helper-exec <vm> --ps 'Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Clipboard]::GetFileDropList().Count'

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct HelperExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper-exec",
        abstract: "通过 HVM guest helper 在 guest 登录用户会话跑命令 (vs exec-guest 的 SYSTEM 会话)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "PowerShell 一行命令 (helper 内部包成 -EncodedCommand UTF16LE, 免 shell quote / IME)")
    var ps: String?

    @Option(name: .long, help: "cmd.exe 一行命令 (helper 内部走 cmd /c)")
    var cmd: String?

    @Option(name: .long, help: "guest 侧执行超时秒数, 到则 helper kill 子进程 exit=-1 (default 60)")
    var timeoutSec: Int = 60

    @Option(name: .long, help: "输出格式: human | json (default human; human 自动 base64 解码 stdout / stderr)")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            // helper 自己做 shell 包装 (powershell -EncodedCommand / cmd /c), 这里只传 raw script + shell.
            let shell: String
            let script: String
            if let ps {
                shell = "powershell"; script = ps
            } else if let cmd {
                shell = "cmd"; script = cmd
            } else {
                throw HVMError.config(.invalidEnum(field: "helper-exec", raw: "no-cmd",
                                                    allowed: ["--ps", "--cmd"]))
            }
            let timeoutMs = timeoutSec * 1000
            let resp = try IPCCall.send(
                socketPath: socketPath, op: .dbgHelperExec,
                args: [
                    "shell": shell,
                    "script": script,
                    "timeoutMs": "\(timeoutMs)",
                ],
                // read timeout 必须 ≥ guest 执行 + helper IPC 往返, 给足余量
                timeoutSec: timeoutSec + 15
            )
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgExecPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "helper-exec payload"))
            }
            let stdoutBytes = Data(base64Encoded: payload.stdoutBase64) ?? Data()
            let stderrBytes = Data(base64Encoded: payload.stderrBase64) ?? Data()
            let stdoutStr = String(data: stdoutBytes, encoding: .utf8) ?? ""
            let stderrStr = String(data: stderrBytes, encoding: .utf8) ?? ""
            switch format {
            case .json:
                printJSON([
                    "exitCode": payload.exitCode,
                    "stdout": stdoutStr,
                    "stderr": stderrStr,
                ])
            case .human:
                if !stdoutStr.isEmpty { print(stdoutStr, terminator: stdoutStr.hasSuffix("\n") ? "" : "\n") }
                if !stderrStr.isEmpty {
                    fputs(stderrStr + (stderrStr.hasSuffix("\n") ? "" : "\n"), stderr)
                }
                fputs("[exit=\(payload.exitCode)]\n", stderr)
                if payload.exitCode != 0 {
                    Foundation.exit(Int32(payload.exitCode == -1 ? 124 : payload.exitCode))
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
