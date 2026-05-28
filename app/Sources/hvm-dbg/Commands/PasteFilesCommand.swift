// hvm-dbg/Commands/PasteFilesCommand.swift
// hvm-dbg paste-files — 模拟用户在 FramebufferHostView 按 Cmd+V 的整条 host→guest
// 文件粘贴通路. 设计稿 docs/v3/HOST_FILE_PASTE.md.
//
// 用法:
//   hvm-dbg paste-files <vm> --file /local/a.txt --file /local/b.zip
//
// 区别 `hvm-dbg file push`:
//   - file push 走 qemu-guest-agent (QGA) guest-file-* API, 落 guest 内任意路径,
//     1-10 MB/s, 自动化测试 / 脚本场景用
//   - paste-files 走 SPICE vdagent VD_AGENT_FILE_XFER_*, 落 guest ~/Downloads,
//     ~50 MB/s, 模拟用户交互 + 验证 GUI Cmd+V 后端通路
//
// 配套要求:
//   - VM 在跑 + QEMU 后端 + guest 内 spice-vdagent 服务正常
//   - 单文件 ≤ 4 GiB; 文件夹会被 server 跳过 (返 skipped 项)

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct PasteFilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste-files",
        abstract: "模拟 Cmd+V 把 host 文件流给 guest (走 SPICE vdagent file_xfer, 落 ~/Downloads)"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, parsing: .singleValue,
            help: "要粘贴的 host 文件路径; 可指定多次 (--file a --file b)")
    var file: [String]

    @Option(name: .long, help: "整体超时秒数 (default 1800; 大批量大文件可拉高)")
    var timeoutSec: Int = 1800

    @Option(name: .long, help: "输出格式: human | json (default human)")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            guard !file.isEmpty else {
                throw HVMError.config(.missingField(name: "至少一个 --file"))
            }
            // host 路径展开 + 存在性检查 (server 端也会查, 这里前置一次避免无意义 IPC)
            let paths: [String] = try file.map { raw -> String in
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw HVMError.config(.invalidEnum(field: "file", raw: url.path,
                                                       allowed: ["existing host file"]))
                }
                return url.path
            }
            // 编码 JSON
            let pathsData = try JSONEncoder().encode(paths)
            guard let pathsStr = String(data: pathsData, encoding: .utf8) else {
                throw HVMError.ipc(.decodeFailed(reason: "encode paths"))
            }
            let socketPath = try IPCCall.socketPath(forVM: vm)

            if format == .human {
                fputs("[paste-files] \(paths.count) 个文件 → \(vm)\n", stderr)
                for p in paths { fputs("  · \(p)\n", stderr) }
            }

            let resp = try IPCCall.send(
                socketPath: socketPath, op: .clipboardPasteFiles,
                args: ["paths": pathsStr],
                timeoutSec: timeoutSec
            )
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCClipboardPasteFilesPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "paste-files payload"))
            }
            printResult(payload, format: format)
            // 如果有 failed, 退出码非 0 方便 CI/脚本判失败 (skipped 不算失败 — 是已知拒绝项)
            if !payload.failed.isEmpty {
                throw ExitCode(2)
            }
        } catch let e as ExitCode {
            throw e
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }

    private func printResult(_ payload: IPCClipboardPasteFilesPayload, format: OutputFormat) {
        switch format {
        case .json:
            var obj: [String: Any] = [
                "successful": payload.successful.map { ["path": $0.path] },
                "skipped":    payload.skipped.map    { ["path": $0.path, "reason": $0.reason] },
                "failed":     payload.failed.map     { ["path": $0.path, "reason": $0.reason] },
            ]
            obj["counts"] = [
                "successful": payload.successful.count,
                "skipped":    payload.skipped.count,
                "failed":     payload.failed.count,
            ]
            printJSON(obj)
        case .human:
            fputs("[paste-files] done — 成功 \(payload.successful.count) · 跳过 \(payload.skipped.count) · 失败 \(payload.failed.count)\n", stderr)
            for s in payload.successful { fputs("  ✔ \(s.path)\n", stderr) }
            for s in payload.skipped    { fputs("  ⊘ \(s.path) — \(s.reason)\n", stderr) }
            for s in payload.failed     { fputs("  ✗ \(s.path) — \(s.reason)\n", stderr) }
        }
    }
}
