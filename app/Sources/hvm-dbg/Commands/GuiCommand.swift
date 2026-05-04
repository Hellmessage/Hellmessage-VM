// hvm-dbg/Commands/GuiCommand.swift
// hvm-dbg gui — 跟 HVM GUI 主进程对话 (HDP-GUI 协议).
// 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md.
//
// 子命令 (PR-G1 仅 ping / screenshot; G2-G4 扩):
//   - hvm-dbg gui ping        健康探测, 验证 server 已启
//   - hvm-dbg gui screenshot  截当前主窗口 + 弹层 → PNG
//
// 前置: HVM 主进程必须以 HVM_GUI_PROBE=1 启动, server 才会监听 socket.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct GuiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gui",
        abstract: "跟 HVM 主进程 GUI 对话 (HDP-GUI 测试协议)",
        subcommands: [
            GuiPingCommand.self,
            GuiScreenshotCommand.self,
        ]
    )
}

// MARK: - 共享 helpers

private enum GuiSocket {
    /// HDP-GUI 服务端 socket 路径 (跟 HVMGuiProbe.ProbeServer.defaultSocketPath 对齐).
    static var path: String {
        HVMPaths.runDir.appendingPathComponent("hvm-dbg-gui.sock").path
    }

    /// 发请求 + 解析响应. 失败抛 HVMError.ipc.*.
    static func request(op: String, args: [String: String] = [:]) throws -> IPCResponse {
        let req = IPCRequest(op: op, args: args)
        let resp = try SocketClient.request(socketPath: path, request: req, timeoutSec: 30)
        guard resp.ok else {
            let code = resp.error?.code ?? "ipc.remote_error"
            let msg = resp.error?.message ?? "unknown remote error"
            throw HVMError.ipc(.remoteError(code: code, message: msg))
        }
        return resp
    }

    /// 友好提示: server 没启动时给用户清晰指引.
    static func wrappedRequest(op: String, args: [String: String] = [:]) throws -> IPCResponse {
        do {
            return try request(op: op, args: args)
        } catch HVMError.ipc(.socketNotFound) {
            throw HVMError.ipc(.socketNotFound(
                path: "\(path) (HVM 主进程未以 HVM_GUI_PROBE=1 启动 — 改用 HVM_GUI_PROBE=1 open build/HVM.app)"
            ))
        }
    }
}

// MARK: - gui ping

struct GuiPingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "ping HDP-GUI server (验证已启)"
    )

    func run() async throws {
        do {
            let resp = try GuiSocket.wrappedRequest(op: "gui.ping")
            let pong = resp.data?["pong"] ?? "?"
            let ver  = resp.data?["version"] ?? "?"
            print("✔ pong (server version: \(ver))")
            _ = pong
        } catch {
            bail(error)
        }
    }
}

// MARK: - gui screenshot

struct GuiScreenshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "截 HVM 主窗口 (含 dialog) → PNG"
    )

    @Option(name: .long, help: "输出文件路径 (默认 stdout 二进制)")
    var output: String?

    func run() async throws {
        do {
            let resp = try GuiSocket.wrappedRequest(op: "gui.screenshot")
            guard let b64 = resp.data?["png_base64"],
                  let png = Data(base64Encoded: b64) else {
                throw HVMError.ipc(.decodeFailed(reason: "gui.screenshot 无 png_base64"))
            }

            if let path = output {
                try png.write(to: URL(fileURLWithPath: path))
                fputs("✔ 已保存 \(path) (\(png.count) bytes)\n", stderr)
            } else {
                FileHandle.standardOutput.write(png)
            }
        } catch {
            bail(error)
        }
    }
}
