// CloneCommand.swift
// hvm-cli clone — 整 VM 克隆 (APFS clonefile + 身份字段重生).
// 必须 VM stopped: CloneManager 内部抢源 .edit lock 排他, 与 .runtime 冲突直接抛 .busy.
//
// 加密 VM clone (D9 = 等价复制 + 同密码):
//   - prompt 源密码 → unlock 拿 sub keys → 字节复制 + 用源 sub.config 重新加密 config
//   - clone 出来跟源同密码; 想换密码自跑 hvm-cli rekey
//
// 实现见 HVMStorage/CloneManager.swift; 设计稿 docs/v3/CLONE.md + CLONE_SNAPSHOT_ENCRYPTED.md.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
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

    @Flag(name: .long, help: "跳过加密 VM 二次确认 (默认会要求 y/N)")
    var force: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let sourceBundle = try BundleResolve.resolve(vm)

            // 加密源 VM: prompt 密码 + 二次确认 (说清"同密码"语义)
            var password: String? = nil
            if let scheme = EncryptedBundleIO.detectScheme(at: sourceBundle) {
                guard scheme == .qemuPerfile else {
                    throw HVMError.encryption(.parseFailed(
                        reason: "VZ-sparsebundle 加密 VM clone 暂未实现 (ENCRYPTION.md v2.4 QEMU 优先)"
                    ))
                }
                if format == .human {
                    print("⚠ 即将克隆加密 VM:")
                    print("  - 字节级 COW 复制 (LUKS qcow2 / config.yaml.enc / swtpm state)")
                    print("  - 新 VM 与源 VM 同密码 (clone 不改密码)")
                    print("  - 想要不同密码: clone 完成后自跑 hvm-cli rekey \(name)")
                    print("  - tpm/ 字节复制: Win VM 同 BitLocker 状态; 双开会触发 BitLocker recovery")
                    print("")
                    if !force {
                        print("继续? [y/N] ", terminator: "")
                        let line = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                        if !["y", "yes"].contains(line) {
                            print("已取消")
                            return
                        }
                    }
                }
                password = try PasswordPrompt.read(prompt: "源 VM 密码: ")
            }

            let targetParent: URL? = targetDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

            let opts = CloneManager.Options(
                newDisplayName: name,
                targetParentDir: targetParent,
                keepMACAddresses: keepMac,
                password: password
            )

            let result = try CloneManager.clone(sourceBundle: sourceBundle, options: opts)

            switch format {
            case .human:
                print("✔ 克隆完成")
                print("  源:     \(result.sourceBundle.path)")
                print("  目标:   \(result.targetBundle.path)")
                print("  新 ID:  \(result.newID.uuidString)")
                if password != nil {
                    print("  ⓘ 新 VM 同源密码; 启动用 hvm-cli start \(name)")
                }
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
                    let encrypted: Bool
                    let renamedDataDisks: [String: String]
                }
                printJSON(Out(
                    ok: true,
                    source: result.sourceBundle.path,
                    target: result.targetBundle.path,
                    newId: result.newID.uuidString,
                    encrypted: password != nil,
                    renamedDataDisks: result.renamedDataDiskUUID8s
                ))
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
