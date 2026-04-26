// hvm-dbg/Commands/MouseCommand.swift
// hvm-dbg mouse <vm> <op> [opts] — 鼠标事件注入.
//
// 坐标系: guest 像素左上原点. CLI 接受 "x,y" 格式. VMHost 侧 MouseEmulator 翻成 view 内点 + window 坐标.
//
// 例:
//   hvm-dbg mouse foo move --to 640,360
//   hvm-dbg mouse foo click --at 640,360 --button right
//   hvm-dbg mouse foo double-click --at 100,200
//   hvm-dbg mouse foo drag --from 50,50 --to 500,500

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct MouseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mouse",
        abstract: "鼠标事件 (move / click / double-click / drag)"
    )

    enum Op: String, ExpressibleByArgument, Sendable {
        case move, click
        case doubleClick = "double-click"
        case drag
    }

    enum Button: String, ExpressibleByArgument, Sendable {
        case left, right, middle
    }

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "操作: move | click | double-click | drag")
    var op: Op

    @Option(name: .long, help: "目标坐标 \"x,y\" (move 用)")
    var to: String?

    @Option(name: .long, help: "目标坐标 \"x,y\" (click / double-click 用)")
    var at: String?

    @Option(name: .long, help: "起点坐标 \"x,y\" (drag 用)")
    var from: String?

    @Option(name: .long, help: "鼠标按键 (default left)")
    var button: Button = .left

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            var args: [String: String] = [
                "op": op.rawValue,
                "button": button.rawValue,
            ]

            switch op {
            case .move:
                guard let s = to else { throw HVMError.config(.missingField(name: "--to")) }
                let (x, y) = try parsePair(s, label: "to")
                args["x"] = "\(x)"; args["y"] = "\(y)"
            case .click, .doubleClick:
                guard let s = at else { throw HVMError.config(.missingField(name: "--at")) }
                let (x, y) = try parsePair(s, label: "at")
                args["x"] = "\(x)"; args["y"] = "\(y)"
            case .drag:
                guard let f = from else { throw HVMError.config(.missingField(name: "--from")) }
                guard let t = to   else { throw HVMError.config(.missingField(name: "--to")) }
                let (x1, y1) = try parsePair(f, label: "from")
                let (x2, y2) = try parsePair(t, label: "to")
                args["x"]  = "\(x1)"; args["y"]  = "\(y1)"
                args["x2"] = "\(x2)"; args["y2"] = "\(y2)"
            }

            let socketPath = try IPCCall.socketPath(forVM: vm)
            _ = try IPCCall.send(socketPath: socketPath, op: .dbgMouse, args: args)

            switch format {
            case .json:  printJSON(["ok": true])
            case .human: print("✔ 已注入 \(op.rawValue)")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func parsePair(_ s: String, label: String) throws -> (Double, Double) {
        let parts = s.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw HVMError.config(.invalidEnum(field: label, raw: s, allowed: ["x,y"]))
        }
        return (x, y)
    }
}
