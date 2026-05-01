// hvm-dbg/Commands/DisplayInfoCommand.swift
// hvm-dbg display-info — 拿 guest 真实当前 framebuffer 尺寸 (通过 QMP screendump → PPM header).
//
// 用途: 验证 spice-vdagent dynamic resize 是否真生效.
//   resize 触发前后两次 display-info 对比 widthPx/heightPx 是否变化:
//     1. hvm-dbg display-info Win   → 比如 1920x1080
//     2. hvm-dbg display-resize Win --width 1280 --height 720
//     3. sleep 3
//     4. hvm-dbg display-info Win   → 期望 1280x720 (说明 vdagent → viogpudo SetDisplayConfig 真生效)
//
// 跟 hvm-dbg status 不同: status 返回的 guestResolution 是写死的 defaultFramebufferSize
// 估算值, 不反映 guest 实际状态; display-info 走 QMP screendump 读 PPM header,
// 拿的是 guest 当前 framebuffer 真实尺寸.
//
// 走 host 子进程 IPC socket (跟 status / screenshot 同), 不依赖 GUI 在跑.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct DisplayInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display-info",
        abstract: "获取 guest 当前真实 framebuffer 尺寸 (验证 dynamic resize 是否生效)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(socketPath: socketPath, op: .dbgDisplayInfo)
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgDisplayInfoPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "display info payload"))
            }
            switch format {
            case .json:
                printJSON([
                    "widthPx": payload.widthPx,
                    "heightPx": payload.heightPx,
                ])
            case .human:
                print("\(payload.widthPx)x\(payload.heightPx)")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
