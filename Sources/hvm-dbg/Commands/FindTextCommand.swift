// hvm-dbg/Commands/FindTextCommand.swift
// hvm-dbg find-text — 抓屏 + OCR + 子串匹配. 找到返回 bbox + center, 找不到 exit 23.
//
// 与 mouse click --at 配合可在不知坐标的情况下点按钮:
//   center=$(hvm-dbg find-text foo "Sign In" | jq -r '.center | "\(.[0]),\(.[1])"')
//   hvm-dbg mouse foo click --at "$center"

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct FindTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find-text",
        abstract: "抓屏 + OCR, 找子串返回 bbox + center"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "要找的子串 (大小写不敏感)")
    var query: String

    @Option(name: .long, help: "输出格式: human | json (default json)")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgFindText,
                                         args: ["query": query], timeoutSec: 30)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgFindTextPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "find_text payload"))
            }

            if !payload.match {
                switch format {
                case .json:
                    printJSON(["match": false])
                case .human:
                    fputs("✗ 未找到 \"\(query)\"\n", stderr)
                }
                throw ExitCode(23)  // dbg.no_match, 与 OutputFormat.exitCode 表对齐
            }

            switch format {
            case .json:
                printJSON([
                    "match":      true,
                    "bbox":       [payload.x ?? 0, payload.y ?? 0,
                                   (payload.x ?? 0) + (payload.width ?? 0),
                                   (payload.y ?? 0) + (payload.height ?? 0)],
                    "center":     [payload.centerX ?? 0, payload.centerY ?? 0],
                    "text":       payload.text ?? "",
                    "confidence": payload.confidence ?? 0,
                ])
            case .human:
                print("✔ 找到 \"\(payload.text ?? "")\" @ (\(payload.centerX ?? 0), \(payload.centerY ?? 0))  conf=\(String(format: "%.2f", payload.confidence ?? 0))")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
