// hvm-dbg/Commands/WaitCommand.swift
// hvm-dbg wait — 轮询等 guest 进入某状态. 客户端实现, 复用 dbgStatus / dbgFindText IPC.
//
// 模式:
//   --for text  --match "..."         OCR 找文字, 命中即返回
//   --for state --eq running          dbg.status state 字段匹配
//   --for frame-stable --within 2     连续 N 秒 lastFrameSha256 不变
//
// 退出码: 0 = 达成, 6 = 超时.

import ArgumentParser
import Foundation
import HVMCore
import HVMIPC

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "轮询等 guest 进入某状态 (text / state / frame-stable)"
    )

    enum Mode: String, ExpressibleByArgument, Sendable {
        case text, state
        case frameStable = "frame-stable"
    }

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "等待模式: text | state | frame-stable")
    var `for`: Mode

    @Option(name: .long, help: "text 模式: 要找的子串")
    var match: String?

    @Option(name: .long, help: "state 模式: 期望 state (running / stopped / paused / starting / stopping)")
    var eq: String?

    @Option(name: .long, help: "frame-stable 模式: 连续多少秒 sha 不变 (default 2)")
    var within: Double = 2.0

    @Option(name: .long, help: "总超时秒 (default 60)")
    var timeout: Double = 60

    @Option(name: .long, help: "轮询间隔秒 (default 1.0)")
    var interval: Double = 1.0

    @Option(name: .long, help: "输出格式: human | json (default json, agent 友好)")
    var format: OutputFormat = .json

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let deadline = Date().addingTimeInterval(timeout)
            let intervalNs = UInt64(interval * 1_000_000_000)

            switch `for` {
            case .text:
                guard let needle = match, !needle.isEmpty else {
                    throw HVMError.config(.missingField(name: "--match"))
                }
                while Date() < deadline {
                    let resp = try IPCCall.send(socketPath: socketPath, op: .dbgFindText,
                                                 args: ["query": needle], timeoutSec: 30)
                    if let json = resp.data?["payload"],
                       let data = json.data(using: .utf8),
                       let p = try? JSONDecoder().decode(IPCDbgFindTextPayload.self, from: data),
                       p.match {
                        succeed(["match": true, "center": [p.centerX ?? 0, p.centerY ?? 0]])
                        return
                    }
                    try await Task.sleep(nanoseconds: intervalNs)
                }
                fail("超时未找到 \"\(needle)\"")

            case .state:
                guard let want = eq, !want.isEmpty else {
                    throw HVMError.config(.missingField(name: "--eq"))
                }
                while Date() < deadline {
                    let resp = try IPCCall.send(socketPath: socketPath, op: .dbgStatus)
                    if let json = resp.data?["payload"],
                       let data = json.data(using: .utf8),
                       let p = try? JSONDecoder().decode(IPCDbgStatusPayload.self, from: data),
                       p.state == want {
                        succeed(["match": true, "state": p.state])
                        return
                    }
                    try await Task.sleep(nanoseconds: intervalNs)
                }
                fail("超时, state 未变成 \(want)")

            case .frameStable:
                // 用 dbgScreenshot 获取真实最新 sha (status 的 lastFrameSha 只有截过图才会更新).
                var lastSha: String? = nil
                var stableSince: Date? = nil
                while Date() < deadline {
                    let resp = try IPCCall.send(socketPath: socketPath, op: .dbgScreenshot, timeoutSec: 30)
                    guard let json = resp.data?["payload"],
                          let data = json.data(using: .utf8),
                          let p = try? JSONDecoder().decode(IPCDbgScreenshotPayload.self, from: data) else {
                        throw HVMError.ipc(.decodeFailed(reason: "screenshot payload"))
                    }
                    let sha = p.sha256
                    if sha == lastSha {
                        if let since = stableSince {
                            if Date().timeIntervalSince(since) >= within {
                                succeed(["match": true, "stableSec": within, "sha256": sha])
                                return
                            }
                        } else {
                            stableSince = Date()
                        }
                    } else {
                        lastSha = sha
                        stableSince = Date()
                    }
                    try await Task.sleep(nanoseconds: intervalNs)
                }
                fail("超时, frame 未稳定")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func succeed(_ payload: [String: Any]) {
        switch format {
        case .json:  printJSON(payload)
        case .human: print("✔ 达成")
        }
    }

    private func fail(_ reason: String) -> Never {
        switch format {
        case .json:  printJSON(["match": false, "reason": reason])
        case .human: fputs("✗ \(reason)\n", stderr)
        }
        // ipc.timed_out → exit 6, 与 hvm-cli / docs/DEBUG_PROBE.md 退出码对齐
        Foundation.exit(6)
    }
}
