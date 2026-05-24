// HVMQemu/QgaDir.swift
//
// guest 文件系统目录列表 — 给 GUI "从 VM 取文件" 浏览器 / hvm-dbg dir ls 用.
// 走 qemu-guest-agent guest-exec 跑 PowerShell (Win) / find (Linux) 拿目录条目.
//
// 输出协议: 每条目一行, **tab 分隔** 3 字段:
//   <type>\t<size>\t<fullPath>
// 其中 type = "D" (目录) / "F" (文件), size 是字节数 (目录恒为 0).
//
// 设计取向:
//   - 不用 JSON: PowerShell ConvertTo-Json 在空数组 / 单元素 时输出不稳定; tab 分隔最简
//   - tab 在文件名里极罕见 (Win / Linux 都允许但用户基本不用), 不做转义
//   - 名字带 \n 的会被 find 默认行为破坏 (find 不转义), 但同样几乎没人这么命名; v2 再考虑
//   - 隐藏文件 / system file 一并列出 (Win -Force, Linux find -mindepth 1)
//
// 性能: PowerShell 启动 + cmdlet 跑 ~1-2 秒 per 调用. Linux find ~100ms. UI 端务必
// async 显示 loading. 大目录 (10k+ 文件) 慢但可用.

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
        case .macOS:
            throw DirError.unsupportedGuestOS("macOS guest 不支持 (无 qga, 走 VZ shared dir 通路推后)")
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
        // GNU find 自带 -printf, Ubuntu/Debian/Arch/Fedora 默认. busybox find 不支持
        // (Alpine/OpenWrt), 用户撞了再单独 fallback. %y=type %s=size %p=fullpath
        // type: 'd'=dir, 'f'=file, 'l'=symlink, 其他略走 'F' 兜底 (parse 时转大写)
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
        // **重要**: Swift `\r\n` 是单一 grapheme Character, split { $0 == "\n" || $0 == "\r" }
        // 漏切 Windows CRLF 行 — 实测 PowerShell stdout 全部塞进一个 entry. 先剥 \r 再按 \n 切.
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
