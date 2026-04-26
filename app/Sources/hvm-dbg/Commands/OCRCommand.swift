// hvm-dbg/Commands/OCRCommand.swift
// hvm-dbg ocr — 抓 frame buffer + Vision framework OCR. 全屏或裁剪 region.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct OCRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "抓屏 + 文字识别 (Vision framework)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "裁剪区域 \"x,y,width,height\" (guest 像素左上原点); 不给 = 全屏")
    var region: String?

    @Option(name: .long, help: "输出格式: human | json (default json)")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            var args: [String: String] = [:]
            if let r = region {
                let parts = r.split(separator: ",")
                guard parts.count == 4,
                      let x = Double(parts[0]), let y = Double(parts[1]),
                      let w = Double(parts[2]), let h = Double(parts[3]) else {
                    throw HVMError.config(.invalidEnum(field: "region", raw: r,
                                                        allowed: ["x,y,width,height"]))
                }
                args = ["x": "\(x)", "y": "\(y)", "w": "\(w)", "h": "\(h)"]
            }

            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgOcr, args: args, timeoutSec: 30)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgOcrPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "ocr payload"))
            }

            switch format {
            case .json:
                let texts = payload.texts.map { item -> [String: Any] in
                    [
                        "bbox": [item.x, item.y, item.x + item.width, item.y + item.height],
                        "text": item.text,
                        "confidence": item.confidence,
                    ]
                }
                printJSON([
                    "widthPx": payload.widthPx,
                    "heightPx": payload.heightPx,
                    "texts": texts,
                ])
            case .human:
                print("\(payload.widthPx) x \(payload.heightPx)  texts=\(payload.texts.count)")
                for it in payload.texts {
                    let conf = String(format: "%.2f", it.confidence)
                    print("  [\(it.x),\(it.y)+\(it.width)x\(it.height)] (\(conf)) \(it.text)")
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
