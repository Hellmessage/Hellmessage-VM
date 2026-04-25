// hvm-dbg/Commands/ConsoleCommand.swift
// hvm-dbg console — 读/写 guest 的 virtio-console (hvc0).
//
// 模式:
//   --read [--since-bytes N]                         拉 [N, totalBytes) 的 guest stdout (base64 解码后输出原始字节)
//   --write "<text>"                                 把 text 当 UTF-8 写入 guest stdin
//   --write-stdin                                    从 host stdin 读字节流写入 guest stdin
//
// 设计要点:
//   - 不做流式 attach. AI agent 用 read+write 组合即可, 真要交互式 tty 走 ssh.
//   - --read 默认 sinceBytes=0 = 拿 ring buffer 全量, 客户端拿响应里的 totalBytes 当下次起点.
//   - --read 输出是 base64 解码后的原始字节 (二进制 escape 序列也保留, 不强行 utf-8 解码).
//   - --format json 时 read 输出整段 JSON, write 输出 { ok: true, bytesWritten: N }.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct ConsoleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "console",
        abstract: "读/写 guest virtio-console (hvc0), 走 host 侧 ring buffer + tee 日志"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Flag(name: .long, help: "拉 guest stdout (与 --write/--write-stdin 互斥)")
    var read: Bool = false

    @Option(name: .customLong("since-bytes"), help: "read 模式: 起点字节数, 默认 0")
    var sinceBytes: Int = 0

    @Option(name: .long, help: "把指定 text 当 UTF-8 写入 guest stdin (会自动加 \\n? 不加, 自己拼)")
    var write: String?

    @Flag(name: .customLong("write-stdin"), help: "从 host stdin 读字节流写入 guest stdin")
    var writeStdin: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)

            if read {
                try doRead(socketPath: socketPath)
            } else if let text = write {
                try doWrite(socketPath: socketPath, text: text)
            } else if writeStdin {
                let stdin = FileHandle.standardInput
                let data = stdin.readDataToEndOfFile()
                try doWriteRaw(socketPath: socketPath, data: data)
            } else {
                throw HVMError.config(.invalidEnum(field: "console.mode",
                                                    raw: "(none)",
                                                    allowed: ["--read", "--write", "--write-stdin"]))
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func doRead(socketPath: String) throws {
        let resp = try IPCCall.send(socketPath: socketPath, op: .dbgConsoleRead,
                                     args: ["sinceBytes": String(sinceBytes)])
        guard let json = resp.data?["payload"],
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(IPCDbgConsoleReadPayload.self, from: data) else {
            throw HVMError.ipc(.decodeFailed(reason: "console.read payload"))
        }
        let bytes = Data(base64Encoded: payload.dataBase64) ?? Data()
        switch format {
        case .json:
            printJSON([
                "totalBytes":         payload.totalBytes,
                "returnedSinceBytes": payload.returnedSinceBytes,
                "returnedBytes":      bytes.count,
                "dataBase64":         payload.dataBase64,
            ])
        case .human:
            FileHandle.standardOutput.write(bytes)
        }
    }

    private func doWrite(socketPath: String, text: String) throws {
        try doWriteRaw(socketPath: socketPath, data: Data(text.utf8))
    }

    private func doWriteRaw(socketPath: String, data: Data) throws {
        let resp = try IPCCall.send(socketPath: socketPath, op: .dbgConsoleWrite,
                                     args: ["dataBase64": data.base64EncodedString()])
        let written = Int(resp.data?["bytesWritten"] ?? "0") ?? 0
        switch format {
        case .json:
            printJSON(["ok": true, "bytesWritten": written])
        case .human:
            print("wrote \(written) bytes")
        }
    }
}
