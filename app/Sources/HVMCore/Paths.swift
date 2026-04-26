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

    /// 全局日志目录 (每 VM 另有自己的 bundle/logs/)
    public static var logsDir: URL {
        appSupport.appendingPathComponent("logs", isDirectory: true)
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

    /// 对给定 uuid 返回默认 socket 路径
    public static func socketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).sock")
    }

    /// 若目录不存在则创建 (0755)
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        return url
    }
}
