// HVMBundle/BundleLayout.swift
// .hvmz 目录布局的路径助手. 所有相对路径定义集中于此
// 布局规范见 docs/VM_BUNDLE.md

import Foundation

public enum BundleLayout {
    public static let configFileName    = "config.yaml"
    /// 老 .json 文件名, 仅用于 BundleIO 启动时探测并报"已断兼容"错误
    public static let legacyConfigFileName = "config.json"
    public static let lockFileName      = ".lock"
    public static let disksDirName      = "disks"
    public static let auxiliaryDirName  = "auxiliary"
    public static let nvramDirName      = "nvram"
    public static let logsDirName       = "logs"
    public static let metaDirName       = "meta"
    public static let snapshotsDirName  = "snapshots"

    public static let nvramFileName     = "efi-vars.fd"
    public static let auxStorageName    = "aux-storage"
    public static let machineIdentifier = "machine-identifier"
    public static let hardwareModel     = "hardware-model"
    public static let thumbnailName     = "thumbnail.png"

    public static func configURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(configFileName)
    }

    public static func legacyConfigURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(legacyConfigFileName)
    }

    public static func lockURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(lockFileName)
    }

    public static func disksDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(disksDirName, isDirectory: true)
    }

    /// 创建 VM 时根据 engine 选择主盘文件名 (写入 DiskSpec.path 持久化).
    /// 运行时永远从 VMConfig.mainDiskRelPath 读, 不再调用此函数.
    public static func mainDiskFileName(for engine: Engine) -> String {
        switch engine {
        case .vz:   return "os.img"
        case .qemu: return "os.qcow2"
        }
    }

    /// 数据盘文件名同上, 仅创建时用. 运行时走 DiskSpec.path.
    public static func dataDiskFileName(uuid8: String, engine: Engine) -> String {
        switch engine {
        case .vz:   return "data-\(uuid8).img"
        case .qemu: return "data-\(uuid8).qcow2"
        }
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
    // 注: HDP iosurface / 输入 QMP / SPICE main channel 走的 socket 与 console QMP /
    // swtpm 等同走 HVMPaths.runDir 全局风格 (per-uuid), 不在 bundle 内部.
    // 见 HVMPaths.iosurfaceSocketPath / qmpInputSocketPath / spiceSocketPath.

    /// swtpm 持久化 TPM 状态目录 (Win11 NVRAM 表征, 跨重启保留 SecureBoot 信任根)
    public static func tpmStateDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("tpm", isDirectory: true)
    }

    /// AutoUnattend.xml 打包后的 ISO 路径 (Win11 SetupBypass + virtio 驱动自动装).
    /// 由 WindowsUnattend.ensureISO 启动前生成 (幂等), 启动时作为第二个 cdrom 挂入.
    public static func unattendISOURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("unattend.iso")
    }

    /// unattend ISO 的 staging 目录 (打 ISO 前的源文件夹). VM 启动后可清.
    public static func unattendStageDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(".unattend-stage", isDirectory: true)
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
