// hvm-dbg 主入口 (M0 骨架)
// M5 起实装 screenshot / key / mouse / ocr / find-text / wait 等子命令
// 详见 docs/DEBUG_PROBE.md

import ArgumentParser
import HVMCore

@main
struct HvmDbg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvm-dbg",
        abstract: "HVM 调试探针 (替代 osascript UI scripting)",
        version: HVMVersion.displayString
    )

    func run() throws {
        // M0 默认行为: 打印版本信息
        print(HVMVersion.displayString)
        print("(M5 起接入 screenshot / key / mouse / ocr 等子命令)")
    }
}
