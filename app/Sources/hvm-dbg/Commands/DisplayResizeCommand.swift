// hvm-dbg/Commands/DisplayResizeCommand.swift
// hvm-dbg display-resize — 触发 GUI 端等价 onDrawableSizeChange 的 resize 链路
// (HDP RESIZE_REQUEST + vdagent MONITORS_CONFIG), 替代手动拖窗口测试.
//
// 实现走 HVM GUI 主进程的 control IPC socket (guiControlSocketPath), 不走
// host 子进程的 IPC. 因为 fanout / VdagentClient 都在 GUI 主进程, 只有 GUI
// 进程能直接调 fanout.fireResize.
//
// 依赖 GUI 在跑 (HVM.app 打开 + VM 运行). GUI 关闭时 socket 不存在, 会报清晰错误.
//
// 详见 docs/DEBUG_PROBE.md (display-resize 节, 待补).

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct DisplayResizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "display-resize",
        abstract: "触发 guest display resize (RESIZE_REQUEST + vdagent MONITORS_CONFIG)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "目标宽 (像素, > 0)")
    var width: UInt32

    @Option(name: .long, help: "目标高 (像素, > 0)")
    var height: UInt32

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            guard width > 0, height > 0 else {
                throw HVMError.config(.invalidEnum(field: "size", raw: "\(width)x\(height)",
                                                    allowed: ["width 和 height 必须 > 0"]))
            }

            // 找 bundle → load config → 拼 GUI control socket 路径.
            // 不走 BundleLock.inspect.socketPath (那个是 host 子进程的 IPC, 不是 GUI 的).
            let bundleURL = try BundleResolve.resolve(vm)
            let config = try BundleIO.load(from: bundleURL)
            let socketURL = HVMPaths.guiControlSocketPath(for: config.id)
            let socketPath = socketURL.path

            // 检查 GUI control socket 文件是否存在 — 不在意味着 HVM.app 没开 / VM 没在 GUI 里跑.
            guard FileManager.default.fileExists(atPath: socketPath) else {
                throw HVMError.ipc(.socketNotFound(path: socketPath +
                    " (HVM.app 未打开或该 VM 不在 GUI 内运行; display-resize 必须 GUI 模式下用)"))
            }

            let resp = try IPCCall.send(
                socketPath: socketPath, op: .dbgDisplayResize,
                args: ["width": "\(width)", "height": "\(height)"]
            )

            switch format {
            case .json:
                printJSON([
                    "ok": resp.ok,
                    "width": Int(width),
                    "height": Int(height),
                    "vmID": config.id.uuidString,
                ])
            case .human:
                print("✔ resize → \(width)x\(height) (vm=\(config.displayName))")
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
