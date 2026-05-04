// EncryptStatusCommand.swift
// hvm-cli encrypt-status <vm> — 不解密显示 VM 加密信息 (走 routing JSON).
//
// 设计稿 docs/v3/ENCRYPTION.md v2.4 PR-10b.

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMEncryption

struct EncryptStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encrypt-status",
        abstract: "查看 VM 加密状态 (不解密, 走 routing JSON)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "输出格式: human | json")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let bundleURL = try BundleResolve.resolve(vm)
            let scheme = EncryptedBundleIO.detectScheme(at: bundleURL)

            if scheme == nil {
                switch format {
                case .human:
                    print("VM \(vm) 是明文 (无加密)")
                case .json:
                    printJSON(["encrypted": "false", "scheme": "plaintext"])
                }
                return
            }

            let routing: RoutingMetadata
            switch scheme! {
            case .qemuPerfile:
                routing = try RoutingJSON.read(from: RoutingJSON.locationForQemuBundle(bundleURL))
            case .vzSparsebundle:
                routing = try RoutingJSON.read(from: RoutingJSON.locationForSparsebundle(bundleURL))
            }

            switch format {
            case .human:
                print("加密 VM: \(routing.displayName)")
                print("  scheme:        \(routing.scheme.rawValue)")
                print("  routing schema: v\(routing.schemaVersion)")
                print("  vmId:          \(routing.vmId.uuidString)")
                print("  KDF:           \(routing.kdfAlgo)")
                print("    iterations:  \(routing.kdfIterations)")
                print("    salt (b64):  \(routing.kdfSalt.base64EncodedString())")
                print("    keylen:      \(routing.kdfKeylen) bytes")
                if let paths = routing.encryptedPaths {
                    print("  encrypted_paths:")
                    for p in paths { print("    - \(p)") }
                }
                print("  bundle:        \(bundleURL.path)")
            case .json:
                let saltB64 = routing.kdfSalt.base64EncodedString()
                let pathsCsv = routing.encryptedPaths?.joined(separator: ",") ?? ""
                printJSON([
                    "encrypted": "true",
                    "scheme": routing.scheme.rawValue,
                    "schemaVersion": "\(routing.schemaVersion)",
                    "vmId": routing.vmId.uuidString,
                    "displayName": routing.displayName,
                    "kdfAlgo": routing.kdfAlgo,
                    "kdfIterations": "\(routing.kdfIterations)",
                    "kdfSalt": saltB64,
                    "kdfKeylen": "\(routing.kdfKeylen)",
                    "encryptedPaths": pathsCsv,
                    "bundlePath": bundleURL.path,
                ])
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
