// hvm-dbg gui — 跟 HVM GUI 主进程对话 (HDP-GUI 协议).
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
            GuiListCommand.self,
            GuiClickCommand.self,
            GuiTypeCommand.self,
            GuiReadCommand.self,
            GuiTriggerErrorCommand.self,
            GuiDismissErrorCommand.self,
            GuiShowWindowCommand.self,
            GuiSimulateDropCommand.self,
            GuiShowDropOverlayCommand.self,
        ]
    )
}

// MARK: - gui simulate-drop

struct GuiSimulateDropCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simulate-drop",
        abstract: "(测试用) 模拟 host→guest 文件拖放 (绕过 AppKit drag session, 直接走 onFilePaste 闭包)"
    )

    @Option(name: .long, parsing: .singleValue, help: "host 文件路径; 可指定多次")
    var file: [String]

    func run() throws {
        do {
            guard !file.isEmpty else {
                throw HVMError.config(.missingField(name: "至少一个 --file"))
            }
            let paths = file.map { ($0 as NSString).expandingTildeInPath }
            let pathsData = try JSONEncoder().encode(paths)
            guard let pathsStr = String(data: pathsData, encoding: .utf8) else {
                throw HVMError.ipc(.decodeFailed(reason: "encode paths"))
            }
            let resp = try GuiSocket.wrappedRequest(op: "debug.simulate-drop",
                                                    args: ["paths": pathsStr])
            let count = resp.data?["dispatched"] ?? "?"
            print("✔ simulated drop of \(count) files")
        } catch { bail(error) }
    }
}

// MARK: - gui show-drop-overlay

struct GuiShowDropOverlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-drop-overlay",
        abstract: "(测试用) 切 dropOverlay 显示状态 (visual snapshot 验证)"
    )

    @Flag(name: .long, help: "隐藏 overlay (默认显示)")
    var hide: Bool = false

    @Option(name: .long, help: "显示时填的文件数 (默认 1)")
    var count: Int = 1

    func run() throws {
        do {
            let visible = hide ? "false" : "true"
            _ = try GuiSocket.wrappedRequest(op: "debug.show-drop-overlay",
                                              args: ["visible": visible, "count": "\(count)"])
            print(hide ? "✔ hid drop overlay" : "✔ shown drop overlay (count=\(count))")
        } catch { bail(error) }
    }
}

// MARK: - gui show-window

struct GuiShowWindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-window",
        abstract: "(测试用) HVM 在 accessory 模式时主动拉出主窗口"
    )
    func run() throws {
        do {
            _ = try GuiSocket.wrappedRequest(op: "debug.show-window")
            print("✔ requested show main window")
        } catch { bail(error) }
    }
}

// MARK: - gui dismiss-error

struct GuiDismissErrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss-error",
        abstract: "(测试用) 主动 dismiss 当前 ErrorDialog (验 framebuffer 恢复路径)"
    )

    func run() throws {
        do {
            _ = try GuiSocket.wrappedRequest(op: "debug.dismiss-error")
            print("✔ dismissed current ErrorDialog")
        } catch {
            bail(error)
        }
    }
}

// MARK: - gui trigger-error (debug only)

struct GuiTriggerErrorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trigger-error",
        abstract: "(测试用) 给 HVM ErrorPresenter push 一个测试 ErrorDialog (验 dialog z-order)"
    )

    @Option(name: .long, help: "错误标题")
    var title: String = "Test Error"

    @Option(name: .long, help: "错误正文")
    var message: String = "Test error from gui probe"

    @Option(name: .long, help: "详情 (可选)")
    var details: String?

    @Option(name: .long, help: "提示 (可选)")
    var hint: String?

    func run() throws {
        do {
            var args: [String: String] = ["title": title, "message": message]
            if let details { args["details"] = details }
            if let hint { args["hint"] = hint }
            _ = try GuiSocket.wrappedRequest(op: "debug.trigger-error", args: args)
            print("✔ triggered ErrorDialog '\(title)'")
        } catch {
            bail(error)
        }
    }
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

// MARK: - gui list

struct GuiListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列当前主窗口所有打了 accessibilityIdentifier 的控件"
    )

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    @Option(name: .long, help: "过滤 identifier 前缀, 例 'dialog.createVM.'")
    var prefix: String?

    func run() async throws {
        do {
            let resp = try GuiSocket.wrappedRequest(op: "gui.list")
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  var entries = try? JSONDecoder().decode([GuiEntry].self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "gui.list payload"))
            }
            if let pfx = prefix {
                entries = entries.filter { $0.identifier.hasPrefix(pfx) }
            }
            switch format {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let jdata = try? encoder.encode(entries),
                   let s = String(data: jdata, encoding: .utf8) {
                    print(s)
                }
            case .human:
                if entries.isEmpty {
                    print("(no controls with accessibilityIdentifier in current window)")
                    return
                }
                print("IDENTIFIER                                                ROLE              LABEL")
                for e in entries {
                    let id = e.identifier.padding(toLength: 56, withPad: " ", startingAt: 0)
                    let role = e.role.padding(toLength: 18, withPad: " ", startingAt: 0)
                    let lab = e.label.isEmpty ? "—" : e.label
                    print("\(id)\(role)\(lab)")
                }
            }
        } catch {
            bail(error)
        }
    }
}

private struct GuiEntry: Codable {
    let identifier: String
    let label: String
    let role: String
}

// MARK: - gui click

struct GuiClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "点指定 identifier 的控件 (button / toggle 切换)"
    )

    @Option(name: .long, help: "控件 identifier (走 hvm-dbg gui list 拿)")
    var identifier: String

    func run() async throws {
        do {
            _ = try GuiSocket.wrappedRequest(op: "gui.click", args: ["identifier": identifier])
            print("✔ clicked '\(identifier)'")
        } catch {
            bail(error)
        }
    }
}

// MARK: - gui type

struct GuiTypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "给 textField 输文字 (覆盖现有值)"
    )

    @Option(name: .long, help: "控件 identifier")
    var identifier: String

    @Option(name: .long, help: "要输入的文字")
    var text: String

    func run() async throws {
        do {
            _ = try GuiSocket.wrappedRequest(op: "gui.type",
                                              args: ["identifier": identifier, "text": text])
            print("✔ typed into '\(identifier)'")
        } catch {
            bail(error)
        }
    }
}

// MARK: - gui read

struct GuiReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "读 textField / toggle 当前值"
    )

    @Option(name: .long, help: "控件 identifier")
    var identifier: String

    func run() async throws {
        do {
            let resp = try GuiSocket.wrappedRequest(op: "gui.read",
                                                     args: ["identifier": identifier])
            let value = resp.data?["value"] ?? ""
            print(value)
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
