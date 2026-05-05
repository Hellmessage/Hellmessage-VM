// hvm-dbg/Commands/FileCommand.swift
// hvm-dbg file push / pull — host ↔ guest 单文件传输, 走 qemu-guest-agent guest-file-* API.
//
// 设计稿: docs/v3/FILE_COPY.md
//
// 用法:
//   hvm-dbg file push <vm> --src /local/x.iso --dst 'C:\Windows\Temp\x.iso'
//   hvm-dbg file pull <vm> --src 'C:\path\file.log' --dst /local/path.log
//
// 配套要求:
//   - VM 在跑 + qga socket 文件存在 (cold start 让 argv 生效)
//   - guest 内 qemu-ga 服务 attach 到 virtio-serial port org.qemu.guest_agent.0
//
// v1 限制:
//   - 单文件, 不递归 (用户先 zip 后 push)
//   - host → guest 写入非原子 (中断留半成品 dst); guest → host 本地走 .hvm-tmp + rename
//   - 软警告 100 MiB / 硬上限 4 GiB

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

private let kSoftWarnBytes: Int64 = 100 * 1024 * 1024
private let kHardLimitBytes: Int64 = 4 * 1024 * 1024 * 1024

struct FileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file",
        abstract: "host ↔ guest 单文件传输 (qemu-guest-agent guest-file-* API)",
        subcommands: [PushCommand.self, PullCommand.self]
    )

    struct PushCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "push",
            abstract: "host → guest 复制单文件 (覆盖目标; 中断留半成品)"
        )

        @Argument(help: "VM 名称或 bundle 路径")
        var vm: String

        @Option(name: .long, help: "host 本地源文件全路径")
        var src: String

        @Option(name: .long, help: "guest 内目标全路径 (Win: 'C:\\path\\file'; Linux: '/path/file')")
        var dst: String

        @Option(name: .long, help: "整体超时秒数 (default 600)")
        var timeoutSec: Int = 600

        @Option(name: .long, help: "输出格式: human | json (default human)")
        var format: OutputFormat = .human

        func run() async throws {
            do {
                let srcURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: srcURL.path) else {
                    throw HVMError.config(.invalidEnum(field: "src", raw: srcURL.path,
                                                      allowed: ["existing host file"]))
                }
                let size = ((try? FileManager.default.attributesOfItem(atPath: srcURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
                if size > kHardLimitBytes {
                    throw HVMError.config(.invalidEnum(field: "src",
                                                      raw: "\(size) bytes",
                                                      allowed: ["≤ 4 GiB"]))
                }
                if size > kSoftWarnBytes && format == .human {
                    fputs("[file push] 警告: 源文件 \(humanBytes(size)), QGA 通路 1-10 MB/s, 预计耗时较长\n", stderr)
                }
                let socketPath = try IPCCall.socketPath(forVM: vm)
                if format == .human {
                    fputs("[file push] \(srcURL.path) → \(dst) (\(humanBytes(size)))\n", stderr)
                }
                let resp = try IPCCall.send(
                    socketPath: socketPath, op: .dbgFilePush,
                    args: [
                        "localPath": srcURL.path,
                        "remotePath": dst,
                        "timeoutSec": "\(timeoutSec)",
                    ],
                    timeoutSec: timeoutSec + 30  // IPC client 读超时 ≥ host 操作 + buffer
                )
                guard let json = resp.data?["payload"],
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(IPCDbgFileTransferPayload.self, from: data) else {
                    throw HVMError.ipc(.decodeFailed(reason: "file push payload"))
                }
                printResult(payload: payload, op: "push", format: format)
            } catch {
                format == .json ? bailJSON(error) : bail(error)
            }
        }
    }

    struct PullCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "guest → host 复制单文件 (本地 .hvm-tmp + atomic rename)"
        )

        @Argument(help: "VM 名称或 bundle 路径")
        var vm: String

        @Option(name: .long, help: "guest 内源文件全路径")
        var src: String

        @Option(name: .long, help: "host 本地目标全路径 (父目录必须存在)")
        var dst: String

        @Option(name: .long, help: "整体超时秒数 (default 600)")
        var timeoutSec: Int = 600

        @Option(name: .long, help: "输出格式: human | json (default human)")
        var format: OutputFormat = .human

        func run() async throws {
            do {
                let dstURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
                let parentDir = dstURL.deletingLastPathComponent().path
                guard FileManager.default.fileExists(atPath: parentDir) else {
                    throw HVMError.config(.invalidEnum(field: "dst-parent", raw: parentDir,
                                                      allowed: ["existing host directory"]))
                }
                let socketPath = try IPCCall.socketPath(forVM: vm)
                if format == .human {
                    fputs("[file pull] \(src) → \(dstURL.path)\n", stderr)
                }
                let resp = try IPCCall.send(
                    socketPath: socketPath, op: .dbgFilePull,
                    args: [
                        "remotePath": src,
                        "localPath": dstURL.path,
                        "timeoutSec": "\(timeoutSec)",
                    ],
                    timeoutSec: timeoutSec + 30
                )
                guard let json = resp.data?["payload"],
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(IPCDbgFileTransferPayload.self, from: data) else {
                    throw HVMError.ipc(.decodeFailed(reason: "file pull payload"))
                }
                printResult(payload: payload, op: "pull", format: format)
            } catch {
                format == .json ? bailJSON(error) : bail(error)
            }
        }
    }
}

// MARK: - 内部

private func printResult(payload: IPCDbgFileTransferPayload, op: String, format: OutputFormat) {
    let mb = Double(payload.bytesTransferred) / (1024.0 * 1024.0)
    let secs = Double(payload.durationMs) / 1000.0
    let mbps = secs > 0.001 ? mb / secs : 0
    switch format {
    case .json:
        printJSON([
            "bytes": payload.bytesTransferred,
            "durationMs": payload.durationMs,
            "throughputMBps": String(format: "%.2f", mbps),
        ])
    case .human:
        fputs(String(format: "[file %@] done %.2f MB in %.2fs (%.2f MB/s)\n",
                     op, mb, secs, mbps), stderr)
    }
}

private func humanBytes(_ b: Int64) -> String {
    let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
    let d = Double(b)
    if d >= gb { return String(format: "%.2f GiB", d / gb) }
    if d >= mb { return String(format: "%.2f MiB", d / mb) }
    if d >= kb { return String(format: "%.2f KiB", d / kb) }
    return "\(b) B"
}
