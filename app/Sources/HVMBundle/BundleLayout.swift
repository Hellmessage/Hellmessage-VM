// HVMBundle/BundleLayout.swift
// .hvmz 目录布局的路径助手. 所有相对路径定义集中于此.

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
    /// 加密 VM 的 NVRAM 文件名 (LUKS qcow2). 与 nvramFileName 互斥, 看哪个存在判定加密/明文.
    public static let nvramLuksFileName = "efi-vars.qcow2"
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

    /// 创建 VM 时按 engine 选主盘文件名 (写入 DiskSpec.path). 运行时从 VMConfig.mainDiskRelPath 读, 不调此函数.
    public static func mainDiskFileName(for engine: Engine) -> String {
        switch engine {
        case .qemu: return "os.qcow2"
        }
    }

    /// 数据盘文件名同上, 仅创建时用. 运行时走 DiskSpec.path.
    public static func dataDiskFileName(uuid8: String, engine: Engine) -> String {
        switch engine {
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

    /// 加密 NVRAM 路径 (LUKS qcow2). 仅加密 QEMU VM 用.
    public static func nvramLuksURL(_ bundle: URL) -> URL {
        nvramDir(bundle).appendingPathComponent(nvramLuksFileName)
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

    /// serial console 的 Unix socket 运行时路径 (不进 config, 运行时生成).
    /// 注: HDP iosurface / 输入 QMP / vdagent / swtpm 等 socket 走 HVMPaths.runDir (per-uuid), 不在 bundle 内.
    public static func serialSocketURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("run", isDirectory: true).appendingPathComponent("console.sock")
    }

    /// swtpm 持久化 TPM 状态目录 (Win11 NVRAM 表征, 跨重启保留 SecureBoot 信任根)
    public static func tpmStateDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("tpm", isDirectory: true)
    }

    /// AutoUnattend.xml 打包后的 ISO 路径 (Win11 SetupBypass + virtio 驱动自动装).
    /// 由 WindowsUnattend.ensureISO 启动前幂等生成, 启动时作第二个 cdrom 挂入.
    public static func unattendISOURL(_ bundle: URL) -> URL {
        bundle.appendingPathComponent("unattend.iso")
    }

    /// unattend ISO 的 staging 目录 (打 ISO 前的源文件夹). VM 启动后可清.
    public static func unattendStageDir(_ bundle: URL) -> URL {
        bundle.appendingPathComponent(".unattend-stage", isDirectory: true)
    }

    /// 判断相对路径是否落在 disks/ 下 (防越界): 必须以 "disks/" 开头且不含 ".." 回跳.
    public static func isDiskPathInSandbox(_ path: String) -> Bool {
        let comps = (path as NSString).pathComponents
        guard let first = comps.first, first == disksDirName else { return false }
        if comps.contains("..") { return false }
        return true
    }
}
