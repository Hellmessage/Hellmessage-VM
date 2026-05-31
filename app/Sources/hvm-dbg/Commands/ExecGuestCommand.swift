// hvm-dbg exec-guest — 通过 qemu-guest-agent 在 guest 内跑命令拿 stdout/stderr/exit_code.
//
// 不依赖 keyboard typing / OCR / GUI mouse, 端到端验证 guest 行为最可靠通路.
// 配套: guest 内 qemu-ga 服务在跑 + argv 挂 chardev qga (QemuHostEntry 自动 wire).
//
// 用法:
//   hvm-dbg exec-guest <vm> --path powershell.exe --args '-Command' --args 'Get-Date'
//   hvm-dbg exec-guest <vm> --path cmd.exe --args /c --args 'echo hello'
//
// 多个 --args 串成 argv 数组, host 端用 0x1F unit-separator 编码避 shell quote 冲突.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct ExecGuestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec-guest",
        abstract: "通过 qemu-guest-agent 在 guest 内跑命令 (绕过 keyboard / OCR / mouse)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "guest 内可执行 binary 全路径或可执行名 (e.g. powershell.exe / cmd.exe). --ps 优先")
    var path: String?

    @Option(name: .long, parsing: .singleValue, help: "argv 参数 (重复使用传多个, 顺序保留). 注意: 以 - 开头需用 --args=-Foo 格式")
    var args: [String] = []

    @Option(name: .long,
            help: "PowerShell 一行命令 (本地 typed in shell). 自动包成 powershell.exe -NoProfile -EncodedCommand <utf16le-base64>, 绕开 shell quote / IME")
    var ps: String?

    @Option(name: .long, help: "cmd.exe 一行命令. 自动包成 cmd.exe /C <line>")
    var cmd: String?

    @Option(name: .long, help: "整体超时秒数 (default 30)")
    var timeoutSec: Int = 30

    @Option(name: .long, help: "输出格式: human | json (default human; human 自动 base64 解码 stdout / stderr)")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            // 决定最终 path + argv: --ps → powershell -EncodedCommand; --cmd → cmd.exe /C; 否则显式 --path + --args
            let finalPath: String
            let finalArgs: [String]
            if let ps {
                finalPath = "powershell.exe"
                let utf16: [UInt8] = ps.unicodeScalars.flatMap { scalar -> [UInt8] in
                    let v = UInt16(scalar.value)  // assume BMP (PowerShell 实测命令足够)
                    return [UInt8(v & 0xff), UInt8(v >> 8)]
                }
                let encoded = Data(utf16).base64EncodedString()
                finalArgs = ["-NoProfile", "-EncodedCommand", encoded]
            } else if let cmd {
                finalPath = "cmd.exe"
                finalArgs = ["/C", cmd]
            } else if let path {
                finalPath = path
                finalArgs = args
            } else {
                throw HVMError.config(.invalidEnum(field: "exec-guest", raw: "no-cmd",
                                                    allowed: ["--ps", "--cmd", "--path"]))
            }
            let argvEncoded = finalArgs.joined(separator: "\u{1F}")
            let resp = try IPCCall.send(
                socketPath: socketPath, op: .dbgExecGuest,
                args: [
                    "path": finalPath,
                    "argv": argvEncoded,
                    "timeoutSec": "\(timeoutSec)",
                ],
                // read timeout 必须 ≥ guest 执行时间, 否则 client 先 close → host send EPIPE crash; +5s buffer
                timeoutSec: timeoutSec + 5
            )
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgExecPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "exec-guest payload"))
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
