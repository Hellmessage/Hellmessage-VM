// hvm-cli 主入口

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

    /// 覆写默认 main, 在 parse 前装 SIGPIPE ignore (IPC socket 断时 write(2) 不杀进程).
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
