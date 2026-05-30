// hvm-cli 主入口
// 详见 docs/CLI.md

import ArgumentParser
import HVMCore

@main
struct HvmCli: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvm-cli",
        abstract: "HVM 命令行工具",
        version: HVMVersion.displayString,
        subcommands: [
            CreateCommand.self,
            OsImageCommand.self,
            ListCommand.self,
            StatusCommand.self,
            StartCommand.self,
            StopCommand.self,
            KillCommand.self,
            PauseCommand.self,
            ResumeCommand.self,
            DeleteCommand.self,
            CloneCommand.self,
            EncryptCommand.self,
            DecryptCommand.self,
            RekeyCommand.self,
            EncryptStatusCommand.self,
            BootFromDiskCommand.self,
            IsoCommand.self,
            DiskCommand.self,
            ConfigCommand.self,
            SnapshotCommand.self,
            SharedFolderCommand.self,
            LogsCommand.self,
        ]
    )

    /// 覆写默认 main, 在 ArgumentParser parse 前装 SIGPIPE ignore.
    /// 防止 hvm-cli 给 host IPC server 写命令时 (start/stop/...), server 已死或 socket 断,
    /// write(2) 触发 SIGPIPE 直接杀掉 hvm-cli 进程, 报错不友好. 详见 SignalGuard.ignoreSIGPIPE() 注释.
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
