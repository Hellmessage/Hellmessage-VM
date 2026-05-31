// HVMQemu/QgaDir.swift
// guest 文件系统目录列表 (GUI "从 VM 取文件" 浏览器 / hvm-dbg dir ls).
// 走 qemu-guest-agent guest-exec 跑 PowerShell (Win) / find (Linux).
//
// 输出协议: 每条目一行, tab 分隔 3 字段 `<type>\t<size>\t<fullPath>`,
//   type = "D" (目录) / "F" (文件), size 字节数 (目录恒 0).
//   不用 JSON (PowerShell ConvertTo-Json 空/单元素输出不稳定); 文件名带 tab/\n 不转义 (罕见).
//   隐藏文件 / system file 一并列出.
//
// 性能: PowerShell ~1-2s/次, Linux find ~100ms. UI 端 async 显示 loading.

import Foundation
import HVMBundle

public enum QgaDir {

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let fullPath: String
        public let isDir: Bool
        public let size: Int64
        public init(name: String, fullPath: String, isDir: Bool, size: Int64) {
            self.name = name; self.fullPath = fullPath
            self.isDir = isDir; self.size = size
        }
    }

    public enum DirError: Error, Sendable {
        /// guest 内命令返非 0 退出码
        case exitNonZero(exitCode: Int, stderr: String)
        /// 解析 stdout 失败
        case parseFailed(reason: String)
        /// guestOS 不支持目录列表 (macOS guest: 未实现; encrypted: caller 不应该走到这条)
        case unsupportedGuestOS(String)
    }

    /// 列 guest 内某个目录. path 必须是 guest 内的绝对路径 (Win: `C:\Users`; Linux: `/home`).
    /// 返条目按 ( isDir 降序, name 升序 ) 排好 — 目录在前, 名字字母序.
    public static func list(
        socketPath: String,
        guestOS: GuestOSType,
        path: String,
        timeoutSec: Int = 30
    ) async throws -> [Entry] {
        let result: QgaExec.Result
        switch guestOS {
        case .windows:
            result = try await runWindowsList(socketPath: socketPath, path: path, timeoutSec: timeoutSec)
        case .linux:
            result = try await runLinuxList(socketPath: socketPath, path: path, timeoutSec: timeoutSec)
        }

        if result.exitCode != 0 {
            let stderr = decodeBase64(result.stderrBase64)
            throw DirError.exitNonZero(exitCode: result.exitCode, stderr: stderr)
        }
        let stdout = decodeBase64(result.stdoutBase64)
        return try parse(stdout: stdout, fallbackParent: path).sorted(by: { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        })
    }

    // MARK: - guestOS specific 命令

    private static func runWindowsList(
        socketPath: String, path: String, timeoutSec: Int
    ) async throws -> QgaExec.Result {
        // PS 单引号字符串内 ' 转义为 ''. 处理用户路径里带 ' (罕见但合法).
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        let script = """
        $ErrorActionPreference='SilentlyContinue';
        Get-ChildItem -LiteralPath '\(escaped)' -Force | ForEach-Object {
          $t = if ($_.PSIsContainer) { 'D' } else { 'F' };
          $s = if ($_.PSIsContainer) { 0 } else { $_.Length };
          "$t`t$s`t$($_.FullName)"
        }
        """
        return try await QgaExec.run(
            socketPath: socketPath,
            path: "powershell.exe",
            args: ["-NoProfile", "-NonInteractive", "-Command", script],
            timeoutSec: timeoutSec
        )
    }

    private static func runLinuxList(
        socketPath: String, path: String, timeoutSec: Int
    ) async throws -> QgaExec.Result {
        // GNU find -printf (主流发行版默认; busybox find 不支持, 撞了再 fallback).
        // %y=type ('d'/'f'/'l', parse 时转大写) %s=size %p=fullpath
        let script = "find -- \"$1\" -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%p\\n'"
        return try await QgaExec.run(
            socketPath: socketPath,
            path: "/bin/sh",
            args: ["-c", script, "_", path],
            timeoutSec: timeoutSec
        )
    }

    // MARK: - 解析

    private static func parse(stdout: String, fallbackParent: String) throws -> [Entry] {
        var entries: [Entry] = []
        // **重要**: Swift `\r\n` 是单一 grapheme, split { $0 == "\n" } 漏切 Windows CRLF 行.
        // 先剥 \r 再按 \n 切.
        let cleaned = stdout.replacingOccurrences(of: "\r", with: "")
        for rawLine in cleaned.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else {
                throw DirError.parseFailed(reason: "tab field count != 3: \(line)")
            }
            let typeRaw = parts[0].uppercased()
            let sizeStr = parts[1]
            let fullPath = parts[2]
            // type: D/F (Win); d/f/l (Linux find -printf %y). 任何非 D/d 都当作 file (含 symlink).
            let isDir = (typeRaw == "D")
            let size = Int64(sizeStr) ?? 0
            let name = lastComponent(fullPath: fullPath)
            entries.append(Entry(name: name, fullPath: fullPath, isDir: isDir, size: size))
            _ = fallbackParent  // 未来若需要从 name 拼 fullPath 时用 — 当前 find/PS 自带 fullPath
        }
        return entries
    }

    /// 取 path 的"最后一段". Win 用 `\`, Linux 用 `/`. 两种都识 — guest 可能是 Linux 但 host
    /// 解析仍要正确. 简单策略: 取最后一个 `\` 或 `/` 之后的部分; 都没有 → 整串.
    private static func lastComponent(fullPath: String) -> String {
        var idx = fullPath.endIndex
        while idx > fullPath.startIndex {
            let prev = fullPath.index(before: idx)
            let c = fullPath[prev]
            if c == "/" || c == "\\" {
                return String(fullPath[idx..<fullPath.endIndex])
            }
            idx = prev
        }
        return fullPath
    }

    private static func decodeBase64(_ b64: String) -> String {
        guard let data = Data(base64Encoded: b64) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
