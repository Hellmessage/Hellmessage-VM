// ResumeCommand.swift
// hvm-cli resume — 恢复 VM (VZ resume).

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct ResumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resume",
        abstract: "恢复暂停的 VM"
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
            let req = IPCRequest(op: IPCOp.resume.rawValue)
            let resp = try SocketClient.request(socketPath: holder.socketPath, request: req)
            guard resp.ok else {
                throw HVMError.ipc(.remoteError(
                    code: resp.error?.code ?? "ipc.remote_error",
                    message: resp.error?.message ?? "resume 失败"
                ))
            }
            switch format {
            case .human: print("✔ 已恢复运行")
            case .json:  printJSON(["ok": "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
