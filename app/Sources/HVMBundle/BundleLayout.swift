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

    /// 老的常量, 仅 VZ raw 主盘文件名. 新代码请用 mainDiskName(for:).
    public static let mainDiskName      = "os.img"
    /// QEMU 后端的主盘文件名 (qcow2)
    public static let mainDiskNameQcow2 = "os.qcow2"
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

    /// 老 API: 仅适用 VZ raw 主盘. 新代码请用 mainDiskURL(_:engine:).
    public static func mainDiskURL(_ bundle: URL) -> URL {
        disksDir(bundle).appendingPathComponent(mainDiskName)
    }

    /// 按 engine 选择主盘文件名:
    ///   - .vz   → main.img    (raw, VZ 必需)
    ///   - .qemu → main.qcow2  (qcow2)
    public static func mainDiskFileName(for engine: Engine) -> String {
        switch engine {
        case .vz:   return mainDiskName
        case .qemu: return mainDiskNameQcow2
        }
    }

    public static func mainDiskURL(_ bundle: URL, engine: Engine) -> URL {
        disksDir(bundle).appendingPathComponent(mainDiskFileName(for: engine))
    }

    /// 数据盘文件名按 engine 走相同格式; 老 .img 数据盘运行时仍按扩展名走 raw.
    public static func dataDiskFileName(uuid8: String, engine: Engine) -> String {
        switch engine {
        case .vz:   return "data-\(uuid8).img"
        case .qemu: return "data-\(uuid8).qcow2"
        }
    }

    /// 老 API: VZ raw 数据盘. 新代码请用 dataDiskURL(_:uuid8:engine:).
    public static func dataDiskURL(_ bundle: URL, uuid8: String) -> URL {
        disksDir(bundle).appendingPathComponent("data-\(uuid8).img")
    }

    public static func dataDiskURL(_ bundle: URL, uuid8: String, engine: Engine) -> URL {
        disksDir(bundle).appendingPathComponent(dataDiskFileName(uuid8: uuid8, engine: engine))
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

    /// swtpm 持久化 TPM 状态目录 (Win11 NVRAM 表征, 跨重启保留 SecureBoot 信任根)
    public static func tpmStateDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("tpm", isDirectory: true)
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
