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
            InstallCommand.self,
            IpswCommand.self,
            OsImageCommand.self,
            ListCommand.self,
            StatusCommand.self,
            StartCommand.self,
            StopCommand.self,
            KillCommand.self,
            PauseCommand.self,
            ResumeCommand.self,
            DeleteCommand.self,
            BootFromDiskCommand.self,
            IsoCommand.self,
            DiskCommand.self,
            ConfigCommand.self,
            SnapshotCommand.self,
            LogsCommand.self,
        ]
    )
}
