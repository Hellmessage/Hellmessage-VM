// hvm-dbg 主入口
// M5 落地: screenshot / status (本提交). 后续 key / mouse / ocr / find-text / wait 分批接入.
// 详见 docs/DEBUG_PROBE.md

import ArgumentParser
import HVMCore

@main
struct HvmDbg: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvm-dbg",
        abstract: "HVM 调试探针 (替代 osascript UI scripting)",
        version: HVMVersion.displayString,
        subcommands: [
            ScreenshotCommand.self,
            StatusCommand.self,
            KeyCommand.self,
            MouseCommand.self,
            OCRCommand.self,
            FindTextCommand.self,
            WaitCommand.self,
        ]
    )
}
