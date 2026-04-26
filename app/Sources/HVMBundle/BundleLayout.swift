// HVMBundle/BundleLayout.swift
// .hvmz 目录布局的路径助手. 所有相对路径定义集中于此
// 布局规范见 docs/VM_BUNDLE.md

import Foundation

public enum BundleLayout {
    public static let configFileName    = "config.json"
    public static let lockFileName      = ".lock"
    public static let disksDirName      = "disks"
    public static let auxiliaryDirName  = "auxiliary"
    public static let nvramDirName      = "nvram"
    public static let logsDirName       = "logs"
    public static let metaDirName       = "meta"
    public static let snapshotsDirName  = "snapshots"

    public static let mainDiskName      = "main.img"
    public static let nvramFileName     = "efi-vars.fd"
    public static let auxStorageName    = "aux-storage"
    public static let machineIdentifier = "machine-identifier"
    public static let hardwareModel     = "hardware-model"
    public static let thumbnailName     = "thumbnail.png"

    public static func configURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(configFileName)
    }

    public static func lockURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(lockFileName)
    }

    public static func disksDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(disksDirName, isDirectory: true)
    }

    public static func mainDiskURL(_ bundle: URL) -> URL {
        disksDir(bundle).appendingPathComponent(mainDiskName)
    }

    public static func dataDiskURL(_ bundle: URL, uuid8: String) -> URL {
        disksDir(bundle).appendingPathComponent("data-\(uuid8).img")
    }

    public static func auxiliaryDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(auxiliaryDirName, isDirectory: true)
    }

    public static func nvramDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(nvramDirName, isDirectory: true)
    }

    public static func nvramURL(_ bundle: URL) -> URL {
        nvramDir(bundle).appendingPathComponent(nvramFileName)
    }

    public static func logsDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(logsDirName, isDirectory: true)
    }

    public static func metaDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(metaDirName, isDirectory: true)
    }

    public static func snapshotsDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(snapshotsDirName, isDirectory: true)
    }

    public static func snapshotDir(_ bundle: URL, name: String) -> URL {
        snapshotsDir(bundle).appendingPathComponent(name, isDirectory: true)
    }

    /// VZ serial console 的 Unix socket 运行时路径 (不进 config, 运行时生成)
    public static func serialSocketURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("run", isDirectory: true).appendingPathComponent("console.sock")
    }

    /// 判断路径是否落在 disks/ 下 (防越界). path 为 config.json 里的相对路径
    public static func isDiskPathInSandbox(_ path: String) -> Bool {
        // 规范化后必须以 "disks/" 开头且不含 ".." 回跳
        let comps = (path as NSString).pathComponents
        guard let first = comps.first, first == disksDirName else { return false }
        if comps.contains("..") { return false }
        return true
    }
}
