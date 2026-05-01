// hvm-dbg/Commands/DisplayResizeCommand.swift
// hvm-dbg display-resize — 模拟 GUI 拖窗口触发 host → guest resize.
//
// 走 IPC 让 host 子进程 spawn 临时 DisplayChannel + VdagentClient, 走两条通路:
//   A. HDP RESIZE_REQUEST  (Linux virtio-gpu 走这条; ramfb 不消费, 只用于诊断信号到达 QEMU)
//   B. vdagent MONITORS_CONFIG  (Win spice-vdagent → SetDisplayConfig)
//
// **测试规约**: 调用此命令时 GUI 不能同时 attach 该 VM (iosurface / vdagent chardev
// 都是 single-client). 推荐流程: hvm-cli start <vm> 起 host 子进程后立即跑此命令.
//
// 验证 resize 是否生效: 配合 hvm-dbg display-info 前后对比 framebuffer 尺寸.
//   1. hvm-dbg display-info Win
//   2. hvm-dbg display-resize Win --width 1280 --height 720
//   3. sleep 2
//   4. hvm-dbg display-info Win

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct DisplayResizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display-resize",
        abstract: "触发 host → guest dynamic resize (HDP RESIZE_REQUEST + vdagent MONITORS_CONFIG)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "目标 width (px), 640..7680")
    var width: UInt32

    @Option(name: .long, help: "目标 height (px), 480..4320")
    var height: UInt32

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        guard width >= 640, width <= 7680, height >= 480, height <= 4320 else {
            FileHandle.standardError.write(Data("width/height 越界 (允许 640..7680 × 480..4320)\n".utf8))
            throw ExitCode(1)
        }
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(
                socketPath: socketPath,
                op: .dbgDisplayResize,
                args: [
                    "width": String(width),
                    "height": String(height),
                ]
            )
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCDbgDisplayResizePayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "display resize payload"))
            }
            switch format {
            case .json:
                printJSON([
                    "widthPx": payload.widthPx,
                    "heightPx": payload.heightPx,
                    "hdpResult": payload.hdpResult,
                    "vdagentResult": payload.vdagentResult,
                ])
            case .human:
                print("requested \(payload.widthPx)x\(payload.heightPx)")
                print("  HDP RESIZE_REQUEST: \(payload.hdpResult)")
                print("  vdagent MONITORS_CONFIG: \(payload.vdagentResult)")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
