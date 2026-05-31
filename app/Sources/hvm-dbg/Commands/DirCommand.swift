// hvm-dbg dir ls — 列 guest 内目录 (一层), 走 qemu-guest-agent.
//   hvm-dbg dir ls <vm> --path 'C:\Users'   # Windows guest
//   hvm-dbg dir ls <vm> --path /home        # Linux guest

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct DirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dir",
        abstract: "列 guest 内目录 (qemu-guest-agent)",
        subcommands: [LsCommand.self]
    )

    struct LsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ls",
            abstract: "列 guest 内某个目录 (一层, 不递归)"
        )

        @Argument(help: "VM 名称或 bundle 路径")
        var vm: String

        @Option(name: .long, help: "guest 内绝对路径 (Win: 'C:\\Users'; Linux: '/home')")
        var path: String

        @Option(name: .long, help: "超时秒数 (default 30)")
        var timeoutSec: Int = 30

        @Option(name: .long, help: "输出格式: human | json (default human)")
        var format: OutputFormat = .human

        func run() async throws {
            do {
                let socketPath = try IPCCall.socketPath(forVM: vm)
                let resp = try IPCCall.send(
                    socketPath: socketPath, op: .dbgListDir,
                    args: ["path": path, "timeoutSec": "\(timeoutSec)"],
                    timeoutSec: timeoutSec + 5
                )
                guard let json = resp.data?["payload"],
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(IPCDbgListDirPayload.self, from: data) else {
                    throw HVMError.ipc(.decodeFailed(reason: "dir list payload"))
                }
                switch format {
                case .json:
                    printJSON([
                        "path": payload.path,
                        "entries": payload.entries.map { e -> [String: Any] in
                            [
                                "name": e.name,
                                "fullPath": e.fullPath,
                                "isDir": e.isDir,
                                "size": e.size,
                            ]
                        },
                    ])
                case .human:
                    fputs("[dir ls] \(payload.path) (\(payload.entries.count) entries)\n", stderr)
                    for e in payload.entries {
                        let typ = (e.isDir ? "DIR " : "FILE").padding(toLength: 4, withPad: " ", startingAt: 0)
                        let sz  = (e.isDir ? "-" : humanBytes(e.size)).padding(toLength: 10, withPad: " ", startingAt: 0)
                        print("\(typ)  \(sz)  \(e.name)")
                    }
                }
            } catch {
                format == .json ? bailJSON(error) : bail(error)
            }
        }
    }
}

private func humanBytes(_ b: Int64) -> String {
    let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
    let d = Double(b)
    if d >= gb { return String(format: "%.2f GiB", d / gb) }
    if d >= mb { return String(format: "%.2f MiB", d / mb) }
    if d >= kb { return String(format: "%.2f KiB", d / kb) }
    return "\(b) B"
}
