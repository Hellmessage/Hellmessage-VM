// SharedFolderCommand.swift
// hvm-cli shared-folder — 管理 host ↔ guest 共享目录 (SPICE WebDAV).
// 详见 docs/v3/SHARED_FOLDER.md. 仅改 config; mount 在 VM 启动时由 SpiceWebdavServer 接管.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

struct SharedFolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shared-folder",
        abstract: "管理 VM 共享目录 (SPICE WebDAV; QEMU 后端)",
        subcommands: [
            SharedFolderAddCommand.self,
            SharedFolderListCommand.self,
            SharedFolderRemoveCommand.self,
        ]
    )
}

// MARK: - add

struct SharedFolderAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "添加一个共享目录"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "host 端绝对路径")
    var hostPath: String

    @Option(name: .long, help: "友好名 (ASCII alnum + - _), guest 内 WebDAV root 区分用; 默认 host 目录名")
    var name: String?

    @Flag(name: .long, help: "允许写入 (默认只读)")
    var rw: Bool = false

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            // 强制绝对路径 + 真实存在 + 目录
            guard hostPath.hasPrefix("/") else {
                throw HVMError.config(.missingField(name: "hostPath 必须是绝对路径: \(hostPath)"))
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDir), isDir.boolValue else {
                throw HVMError.config(.missingField(name: "hostPath 不是目录或不存在: \(hostPath)"))
            }
            // 计算 name: 用户给 → 校验; 没给 → 取 host 路径 basename + sanitize
            let resolvedName: String
            if let userName = name {
                resolvedName = userName
            } else {
                let base = (hostPath as NSString).lastPathComponent
                resolvedName = SharedFolderSpec.sanitizeName(base)
            }
            try Self.validateName(resolvedName)

            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            // QEMU only 限制 (VZ / macOS guest 推后)
            guard config.engine == .qemu else {
                throw HVMError.config(.invalidEnum(field: "shared-folder.engine",
                                                    raw: "\(config.engine)",
                                                    allowed: ["qemu"]))
            }
            // 重名校验 (单 VM 内 name 唯一)
            if config.sharedFolders.contains(where: { $0.name == resolvedName }) {
                throw HVMError.config(.missingField(name: "共享目录 name 已存在: \(resolvedName) (先 shared-folder remove 再加)"))
            }
            let spec = SharedFolderSpec(hostPath: hostPath, name: resolvedName, readOnly: !rw)
            config.sharedFolders.append(spec)
            try EncryptedConfigEditor.save(config, session: session)

            let mode = rw ? "rw" : "ro"
            switch format {
            case .human:
                print("✔ 已添加共享目录: \(resolvedName) → \(hostPath) [\(mode)]")
                print("  下次启动 VM 时 guest 内自动挂载 (Win: \\\\localhost\\dav; Linux: GVFS davs://localhost/)")
            case .json:
                printJSON(["ok": "true", "name": resolvedName, "hostPath": hostPath, "readOnly": rw ? "false" : "true"])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    /// name 必须 ASCII alphanumeric + `-_`, 1-32 字符. 防 WebDAV URL 注入.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 32 else {
            throw HVMError.config(.missingField(name: "name 长度需 1-32 字符: '\(name)'"))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw HVMError.config(.missingField(name: "name 仅允许 ASCII alnum + - _: '\(name)'"))
        }
    }
}

// MARK: - list

struct SharedFolderListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出 VM 的所有共享目录"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let (config, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            switch format {
            case .human:
                if config.sharedFolders.isEmpty {
                    print("(无共享目录)")
                } else {
                    for (idx, sf) in config.sharedFolders.enumerated() {
                        let mode = sf.readOnly ? "ro" : "rw"
                        print("[\(idx)] \(sf.name)  [\(mode)]  \(sf.hostPath)")
                    }
                }
            case .json:
                let arr: [[String: String]] = config.sharedFolders.map { sf in
                    ["name": sf.name, "hostPath": sf.hostPath, "readOnly": sf.readOnly ? "true" : "false"]
                }
                if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
                   let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

// MARK: - remove

struct SharedFolderRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "移除一个共享目录 (按 name)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Argument(help: "共享目录 name")
    var name: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            if BundleLock.isBusy(bundleURL: bundleURL) {
                throw HVMError.bundle(.busy(pid: 0, holderMode: "runtime"))
            }
            let (loaded, session) = try EncryptedConfigEditor.load(bundleURL: bundleURL)
            defer { try? session.close() }
            var config = loaded
            let before = config.sharedFolders.count
            config.sharedFolders.removeAll { $0.name == name }
            guard config.sharedFolders.count != before else {
                throw HVMError.config(.missingField(name: "共享目录 name 不存在: \(name)"))
            }
            try EncryptedConfigEditor.save(config, session: session)
            switch format {
            case .human: print("✔ 已移除共享目录: \(name)")
            case .json:  printJSON(["ok": "true", "name": name])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}

