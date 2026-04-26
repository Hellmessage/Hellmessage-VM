// hvm-dbg/Commands/BootProgressCommand.swift
// hvm-dbg boot-progress — 启发式判断 guest 启动阶段, 给 AI agent 做粗分支决策.
// 阶段: bios / boot-logo / ready-tty / ready-gui / unknown.
// 详细启发式规则见 docs/DEBUG_PROBE.md boot-progress 章节.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct BootProgressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot-progress",
        abstract: "启发式判断 guest 启动阶段 (bios/boot-logo/ready-tty/ready-gui)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgBootProgress)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgBootProgressPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "dbg boot_progress payload"))
            }

            switch format {
            case .json:
                printJSON([
                    "phase":      payload.phase,
                    "confidence": payload.confidence,
                    "elapsedSec": payload.elapsedSec as Any,
                ])
            case .human:
                print("phase:       \(payload.phase)")
                print("confidence:  \(String(format: "%.2f", payload.confidence))")
                print("elapsedSec:  \(payload.elapsedSec.map(String.init) ?? "—")")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
