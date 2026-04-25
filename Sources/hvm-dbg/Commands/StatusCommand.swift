// hvm-dbg/Commands/StatusCommand.swift
// hvm-dbg status — 偏 guest 视角的运行信息 (区别于 hvm-cli status 的 host 视角).
// 给 AI agent 判断 "画面变了没" / "VM 还在跑没" 用.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "guest 视角的运行信息 (state / 分辨率 / lastFrameSha)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgStatus)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgStatusPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "dbg status payload"))
            }

            switch format {
            case .json:
                printJSON([
                    "state": payload.state,
                    "guestResolution": [
                        "widthPx":  payload.guestWidthPx,
                        "heightPx": payload.guestHeightPx,
                    ],
                    "lastFrameSha256":   payload.lastFrameSha256 as Any,
                    "consoleAgentOnline": payload.consoleAgentOnline,
                ])
            case .human:
                print("state:               \(payload.state)")
                print("guest resolution:    \(payload.guestWidthPx) x \(payload.guestHeightPx)")
                print("last frame sha256:   \(payload.lastFrameSha256 ?? "—")")
                print("console agent:       \(payload.consoleAgentOnline ? "online" : "offline")")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
