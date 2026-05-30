// hvm-dbg display-info — 拿 guest 真实当前 framebuffer 尺寸 (QMP screendump → PPM header).
//
// 用途: 验证 dynamic resize 是否生效, 配合 display-resize 前后对比 widthPx/heightPx.
// 跟 status 不同: status 的 guestResolution 是 defaultFramebufferSize 估算值, 不反映 guest
// 实际状态; 本命令读 PPM header 拿真实尺寸. 走 host 子进程 IPC socket, 不依赖 GUI 在跑.

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
