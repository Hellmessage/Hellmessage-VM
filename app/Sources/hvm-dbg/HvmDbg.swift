// hvm-dbg 主入口

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
            HelperExecCommand.self,
            GuestNetinfoCommand.self,
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

    /// 覆写默认 main, parse 前装 SIGPIPE ignore (qemu-launch 子命令自起 IPC server, 防 client 异常断开).
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
