// CloneCommand.swift
// hvm-cli clone — 整 VM 克隆 (APFS clonefile + 身份字段重生).
// 必须 VM stopped: CloneManager 内部抢源 .edit lock 排他, 与 .runtime 冲突直接抛 .busy.
//
// 实现见 HVMStorage/CloneManager.swift; 设计稿 docs/v3/CLONE.md.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMStorage

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "整 VM 克隆 (APFS clonefile + 身份字段重生). 源必须 stopped, 必须同 APFS 卷"
    )

    @Argument(help: "源 VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "新 VM 显示名 (1-64 字符, 不允许 / 或 NUL)")
    var name: String

    @Option(name: .long, help: "目标父目录, 缺省 = 源父目录 (通常是 ~/Library/Application Support/HVM/VMs)")
    var targetDir: String?

    @Flag(name: .long, help: "保留所有 NIC MAC (默认: 重生; 用户自负同 LAN 不双开)")
    var keepMac: Bool = false

    @Flag(name: .long, help: "复制 snapshots/ 整目录到目标 (默认: 不带)")
    var includeSnapshots: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let sourceBundle = try BundleResolve.resolve(vm)

            let targetParent: URL? = targetDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

            let opts = CloneManager.Options(
                newDisplayName: name,
                targetParentDir: targetParent,
                keepMACAddresses: keepMac,
                includeSnapshots: includeSnapshots
            )

            let result = try CloneManager.clone(sourceBundle: sourceBundle, options: opts)

            switch format {
            case .human:
                print("✔ 克隆完成")
                print("  源:     \(result.sourceBundle.path)")
                print("  目标:   \(result.targetBundle.path)")
                print("  新 ID:  \(result.newID.uuidString)")
                if !result.renamedDataDiskUUID8s.isEmpty {
                    print("  数据盘 uuid8 重生:")
                    for (old, new) in result.renamedDataDiskUUID8s.sorted(by: { $0.key < $1.key }) {
                        print("    \(old) → \(new)")
                    }
                }
            case .json:
                struct Out: Encodable {
                    let ok: Bool
                    let source: String
                    let target: String
                    let newId: String
                    let renamedDataDisks: [String: String]
                }
                printJSON(Out(
                    ok: true,
                    source: result.sourceBundle.path,
                    target: result.targetBundle.path,
                    newId: result.newID.uuidString,
                    renamedDataDisks: result.renamedDataDiskUUID8s
                ))
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
