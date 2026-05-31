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

    /// tray 归属协调锁 (见 TRAY_OWNERSHIP_DESIGN): GUI 进程在世时持有 gui-owner.lock;
    /// 无 GUI 时某个 VMHost 持有 tray-leader.lock 渲染聚合 tray.
    public static var guiOwnerLockPath: URL {
        runDir.appendingPathComponent("gui-owner.lock")
    }
    public static var trayLeaderLockPath: URL {
        runDir.appendingPathComponent("tray-leader.lock")
    }

    /// 全局日志目录. HVM 软件本身的所有 host 侧 .log 都落这里 (顶层 yyyy-MM-dd.log 跨 VM,
    /// 子目录 <displayName>-<uuid8>/ 放该 VM 的 host-/qemu-stderr/swtpm log).
    /// guest 自身串口输出 console-*.log 仍留 bundle/logs/, 不在此处.
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

    /// virtio-win.iso 缓存目录 (Win11 arm64 装机必需的 virtio 驱动 ISO, 全局共享一份)
    public static var virtioWinCacheDir: URL {
        appSupport.appendingPathComponent("cache/virtio-win", isDirectory: true)
    }

    /// UTM Guest Tools ISO 缓存目录 (Win guest 动态 resize 用的 ARM64 vdagent + viogpudo, 全局共享一份)
    public static var utmGuestToolsCacheDir: URL {
        appSupport.appendingPathComponent("cache/utm-guest-tools", isDirectory: true)
    }

    /// Linux / Windows guest ISO 自动下载缓存根目录, 子目录按 family 分
    public static var osImagesCacheDir: URL {
        appSupport.appendingPathComponent("cache/os-images", isDirectory: true)
    }

    /// 对给定 uuid 返回默认 IPC socket 路径 (HVMHost ↔ hvm-cli/hvm-dbg)
    public static func socketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).sock")
    }

    /// QEMU 后端运行时 socket 路径 (per-VM, transient), 由 QemuHostEntry / qemu-launch 共用
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
    /// QEMU 进程的 -pidfile 路径. host 异常退出时 QEMU 会 reparent 到 launchd 成 orphan 占着 fd;
    /// 下次 host 启动前用本 pid 抓老进程 kill 掉. 详见 HVMQemu/SidecarOrphanReaper.
    public static func qemuPidPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).qemu.pid")
    }
    /// QEMU `-display iosurface,socket=...` 的 HDP socket 路径
    /// (host HVMDisplayQemu.DisplayChannel 连此 socket 拉 framebuffer).
    public static func iosurfaceSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).iosurface.sock")
    }
    /// 输入专用 QMP socket (`-qmp unix:...`), 跟控制 QMP 分离避免 accept 争抢.
    /// host HVMDisplayQemu.InputForwarder 走此 socket 发 input-send-event.
    public static func qmpInputSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).qmp.input.sock")
    }
    /// spice-vdagent virtio-serial chardev socket; host 不连, 仅留给 guest agent.
    public static func vdagentSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).vdagent.sock")
    }
    /// qemu-guest-agent 的 virtio-serial chardev socket. host 发 JSON `guest-exec` 在 guest 内
    /// 跑 process 拿 stdout/exit_code, 不依赖 keyboard/OCR/mouse. 由 hvm-dbg exec-guest 使用.
    public static func qgaSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).qga.sock")
    }
    /// SPICE WebDAV virtio-serial chardev socket — host ↔ guest 共享目录.
    /// QEMU 作 chardev server, HVM 主进程 SpiceWebdavServer 作 client; guest 内 spice-webdavd 走 `org.spice-space.webdav.0`.
    public static func webdavSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).webdav.sock")
    }
    /// HVM 自家 guest helper virtio-serial chardev socket — 文件剪贴板.
    /// HVM 主进程 HVMFileClipboardBridge 作 client; guest 内 hvm-guest-helper.exe 走 `com.hellmessage.hvm-clipboard.0` 设 Win 剪贴板.
    public static func hvmClipboardSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).hvm-clipboard.sock")
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
