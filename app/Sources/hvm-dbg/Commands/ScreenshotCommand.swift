// hvm-dbg/Commands/ScreenshotCommand.swift
// hvm-dbg screenshot — 抓 guest 当前 frame buffer, 输出 PNG (stdout 二进制 / 文件 / json base64)
//
// VM 必须在跑 (state=running 或 paused), 否则报 dbg.vm_not_running (exit 20).

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct ScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "抓当前 frame buffer 输出 PNG"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出文件路径; 默认走 stdout 二进制 (json 模式忽略此项)")
    var output: String?

    @Option(name: .long, help: "输出格式: human | json. human 默认输出 PNG 二进制流, json 输出 base64 + 元信息")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgScreenshot)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgScreenshotPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "screenshot payload"))
            }
            guard let pngData = Data(base64Encoded: payload.pngBase64) else {
                throw HVMError.ipc(.decodeFailed(reason: "base64 decode"))
            }

            switch format {
            case .json:
                printJSON([
                    "pngBase64": payload.pngBase64,
                    "widthPx":   payload.widthPx,
                    "heightPx":  payload.heightPx,
                    "sha256":    payload.sha256,
                ])
            case .human:
                if let outPath = output {
                    try pngData.write(to: URL(fileURLWithPath: outPath))
                    fputs("✔ 已保存 \(outPath) (\(payload.widthPx)x\(payload.heightPx), \(pngData.count) bytes)\n", stderr)
                } else {
                    // 二进制 PNG 写 stdout, 不加换行
                    FileHandle.standardOutput.write(pngData)
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
