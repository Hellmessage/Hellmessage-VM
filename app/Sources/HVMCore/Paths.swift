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

    /// UTM Guest Tools ISO 缓存目录, ~/Library/Application Support/HVM/cache/spice-tools
    /// (Win guest 装拖窗口动态 resize 用的 ARM64 native vdagent + utmapp 自家 viogpudo;
    ///  ~120MB; 全局共享一份). 目录名仍叫 spice-tools 是历史原因 (老 cache 用 spice-space.org
    ///  上游 spice-guest-tools.exe), 现迁到 UTM Guest Tools 但目录名保留, 避免迁移老缓存逻辑.
    public static var spiceToolsCacheDir: URL {
        appSupport.appendingPathComponent("cache/spice-tools", isDirectory: true)
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
    /// SPICE main channel unix socket; QEMU `-spice unix=on,addr=...` server,
    /// HVMDisplayQemu.SpiceMainClient 作 client 连进去, 在 main channel 上发
    /// SPICE_MSGC_MAIN_AGENT_DATA 包裹 VDAgentMessage(MONITORS_CONFIG), spice-server
    /// 通过 -chardev spicevmc,name=vdagent multiplex 给 guest 内 spice-vdagent 服务
    /// (vdservice → vdagent.exe → SetDisplayConfig 改分辨率).
    /// 详见 docs/QEMU_INTEGRATION.md vdagent 通路章节.
    public static func spiceSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).spice.sock")
    }
    /// GUI 主进程 control socket; 由 AppModel.ensureQemuFanout 时启的 SocketServer 监听.
    /// 跟 socketPath() (host 子进程的 IPC socket) 区分开. 仅 hvm-dbg display-resize 这种
    /// 需要驱动 GUI 端 onDrawableSizeChange 等价路径的 op 走这条; 其他 dbg.* op 仍走
    /// host 子进程那条 socket. GUI 关闭时该 socket 停, hvm-dbg 拿不到不算 bug.
    public static func guiControlSocketPath(for id: UUID) -> URL {
        runDir.appendingPathComponent("\(id.uuidString.lowercased()).gui.sock")
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
