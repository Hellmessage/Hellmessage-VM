// hvm-dbg/Commands/KeyCommand.swift
// hvm-dbg key — 注入键盘事件到 VZ guest. 走 VZUSBKeyboard NSEvent 路径, 不依赖辅助功能权限.
//
// 两种模式互斥:
//   --text "..."   逐字符敲入 (US ASCII printable + \n \t)
//   --press "..."  组合键, 空格分隔多组动作: "cmd+t" / "Return" / "shift+a cmd+s"
//
// 详见 docs/DEBUG_PROBE.md "key" 节.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct KeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "注入键盘事件 (text 文本 / press 组合键)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "敲入字符串文本 (与 --press 互斥)")
    var text: String?

    @Option(name: .long, help: "组合键序列, 空格分隔: cmd+t / Return / shift+a (与 --text 互斥)")
    var press: String?

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            switch (text, press) {
            case (nil, nil):
                throw HVMError.config(.missingField(name: "--text 或 --press"))
            case (.some, .some):
                throw HVMError.config(.invalidEnum(field: "key.mode", raw: "both",
                                                    allowed: ["--text 或 --press, 不能同时给"]))
            default: break
            }

            let socketPath = try IPCCall.socketPath(forVM: vm)
            var args: [String: String] = [:]
            if let t = text  { args["text"]  = t }
            if let p = press { args["press"] = p }
            _ = try IPCCall.send(socketPath: socketPath, op: .dbgKey, args: args)

            switch format {
            case .json:  printJSON(["ok": true])
            case .human: print("✔ 已注入")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
