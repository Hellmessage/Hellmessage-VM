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
            BootProgressCommand.self,
            ConsoleCommand.self,
            ExecCommand.self,
            ExecGuestCommand.self,
            FileCommand.self,
            PasteFilesCommand.self,
            DirCommand.self,
            DisplayInfoCommand.self,
            DisplayResizeCommand.self,
            QemuLaunchCommand.self,
            GuiCommand.self,
            WebdavTestCommand.self,
            WebdavServeCommand.self,
        ]
    )

    /// 覆写默认 main, 在 ArgumentParser parse 前装 SIGPIPE ignore.
    /// hvm-dbg 本身不太会撞 SIGPIPE (它是 socket 主动方, peer 是 host server), 但 qemu-launch
    /// 子命令会自己起 IPC server, 需要 ignore SIGPIPE 防御 client 异常断开. 详见
    /// SignalGuard.ignoreSIGPIPE() 注释.
    static func main() async {
        SignalGuard.ignoreSIGPIPE()
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
