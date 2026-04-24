// hvm-cli 主入口 (M0 骨架)
// M1 起实装 list / create / start / stop 等子命令, 详见 docs/CLI.md

import ArgumentParser
import HVMCore

@main
struct HvmCli: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hvm-cli",
        abstract: "HVM 命令行工具",
        version: HVMVersion.displayString
    )

    func run() throws {
        // M0 默认行为: 打印版本信息, 提示 M1 将接入子命令
        print(HVMVersion.displayString)
        print("(M1 起接入 create / list / start / stop 等子命令)")
    }
}
