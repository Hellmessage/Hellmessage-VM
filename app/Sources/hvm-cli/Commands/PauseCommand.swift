// PauseCommand.swift
// hvm-cli pause — 暂停 VM (VZ pause). guest 进入挂起态, vCPU 不再调度, 内存保留.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct PauseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "暂停 VM (vCPU 挂起, 内存保留)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            guard let holder = BundleLock.inspect(bundleURL: bundleURL),
                  !holder.socketPath.isEmpty else {
                throw HVMError.ipc(.socketNotFound(path: "(inspect 失败)"))
            }
            let req = IPCRequest(op: IPCOp.pause.rawValue)
            let resp = try SocketClient.request(socketPath: holder.socketPath, request: req)
            guard resp.ok else {
                throw HVMError.ipc(.remoteError(
                    code: resp.error?.code ?? "ipc.remote_error",
                    message: resp.error?.message ?? "pause 失败"
                ))
            }
            switch format {
            case .human: print("✔ 已暂停; 用 hvm-cli resume 继续")
            case .json:  printJSON(["ok": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
