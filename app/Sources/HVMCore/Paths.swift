// HVMCore/Paths.swift
// HVM 用户数据目录. 约束见 CLAUDE.md:
//   ~/Library/Application Support/HVM/{VMs,cache,logs,run}

import Foundation

public enum HVMPaths {
    /// ~/Library/Application Support/HVM
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HVM", isDirectory: true)
    }

    /// bundle 默认落地根, ~/Library/Application Support/HVM/VMs
    public static var vmsRoot: URL {
        appSupport.appendingPathComponent("VMs", isDirectory: true)
    }

    /// IPC socket 落地根, ~/Library/Application Support/HVM/run
    public static var runDir: URL {
        appSupport.appendingPathComponent("run", isDirectory: true)
    }

    /// 全局日志目录. HVM 软件本身的所有 host 侧 .log 都落这里:
    ///   - 顶层 yyyy-MM-dd.log: LogSink mirror 的 os.Logger 输出 (跨 VM)
    ///   - 子目录 <displayName>-<uuid8>/: 该 VM 的 host 侧 .log
    ///       host-<date>.log     ← VMHost (HVM 进程) stdout/stderr
    ///       qemu-stderr.log     ← QEMU host 进程 stderr
    ///       swtpm.log           ← swtpm 自身 log
    ///       swtpm-stderr.log    ← swtpm 进程 stderr
    /// guest 自身串口输出 (console-*.log) 仍留 bundle/logs/, 不在此处.
    public static var logsDir: URL {
        appSupport.appendingPathComponent("logs", isDirectory: true)
    }

    /// 给定 VM 的全局 host 侧日志子目录. 子目录名 <displayName>-<uuid8>, displayName 改名时
    /// 旧目录留为 orphan (排查老问题保留), 不主动清理.
    public static func vmLogsDir(displayName: String, id: UUID) -> URL {
        let uuid8 = id.uuidString.lowercased().prefix(8)
        let safeName = sanitizeForFilesystem(displayName)
        return logsDir.appendingPathComponent("\(safeName)-\(uuid8)", isDirectory: true)
    }

    /// VM displayName 转可作为目录名的 token (剔除 / : 等不友好字符).
    private static func sanitizeForFilesystem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        var out = ""
        for s in raw.unicodeScalars {
            out.append(allowed.contains(s) ? Character(s) : "_")
        }
        return out.isEmpty ? "vm" : out
    }

    /// IPSW 缓存目录, ~/Library/Application Support/HVM/cache/ipsw
    public static var ipswCacheDir: URL {
        appSupport.appendingPathComponent("cache/ipsw", isDirectory: true)
    }

    /// virtio-win.iso 缓存目录, ~/Library/Application Support/HVM/cache/virtio-win
    /// (Win11 arm64 装机必需的 virtio-blk/net/gpu 驱动 ISO; 全局共享一份)
    public static var virtioWinCacheDir: URL {
        appSupport.appendingPathComponent("cache/virtio-win", isDirectory: true)
    }

    /// 对给定 uuid 返回默认 IPC socket 路径 (HVMHost ↔ hvm-cli/hvm-dbg)
    public static func socketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).sock")
    }

    /// QEMU 后端运行时 socket 路径 (per-VM, transient). 由 QemuHostEntry / qemu-launch 共用,
    /// 避免硬编码字符串在多处漂移.
    public static func qmpSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).qmp")
    }
    public static func consoleSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).console.sock")
    }
    public static func swtpmSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).swtpm.sock")
    }
    public static func swtpmPidPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).swtpm.pid")
    }
    // vmnetSocketPath / vmnetPidPath 已废弃: socket_vmnet 改成系统级 launchd daemon
    // (路径见 HVMQemu/VmnetDaemonPaths), 不再 per-VM 起 sidecar.

    /// 若目录不存在则创建 (0755)
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        return url
    }
}
