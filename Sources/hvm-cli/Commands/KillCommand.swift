// KillCommand.swift
// hvm-cli kill — 强制关机 (等同拔电源), 可能丢数据

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct KillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "强制关机 (可能丢数据)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Flag(name: .long, help: "跳过确认")
    var force: Bool = false

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            guard let holder = BundleLock.inspect(bundleURL: bundleURL),
                  !holder.socketPath.isEmpty else {
                throw HVMError.ipc(.socketNotFound(path: "(inspect 失败)"))
            }

            if !force, format == .human {
                print("强制关机可能导致 guest 数据损坏. 继续? [y/N] ", terminator: "")
                let line = readLine() ?? ""
                if !["y", "Y", "yes", "YES"].contains(line.trimmingCharacters(in: .whitespaces)) {
                    print("已取消")
                    return
                }
            }

            let req = IPCRequest(op: IPCOp.kill.rawValue)
            let resp = try SocketClient.request(socketPath: holder.socketPath, request: req)
            guard resp.ok else {
                throw HVMError.ipc(.remoteError(
                    code: resp.error?.code ?? "ipc.remote_error",
                    message: resp.error?.message ?? "kill 失败"
                ))
            }
            switch format {
            case .human: print("✔ 已强制关机")
            case .json:  printJSON(["ok": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
