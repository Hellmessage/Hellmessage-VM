// HVMCore/SocketPaths.swift
// socket_vmnet daemon 的标准 socket 路径集中常量, 避免多处硬编字面量漂移.
// 路径与 socket_vmnet 上游 / lima / hell-vm 一致, 跨工具复用同一 daemon.
import Foundation

public enum SocketPaths {
    /// socket_vmnet 默认基路径 (/var/run/socket_vmnet)
    /// scripts/install-vmnet-daemons.sh 与 socket_vmnet 上游 / lima / hell-vm 保持一致
    public static let vmnetBase = "/var/run/socket_vmnet"

    /// shared 模式 (NAT+DHCP) socket
    public static var vmnetShared: String { vmnetBase }

    /// host-only 模式 socket
    public static var vmnetHost: String { vmnetBase + ".host" }

    /// bridged 模式 socket: 每块宿主 NIC 独立一个 daemon + 独立 socket
    public static func vmnetBridged(interface: String) -> String {
        vmnetBase + ".bridged.\(interface)"
    }

    /// 检测 daemon socket 是否就绪 (文件存在 + 是 unix socket).
    /// 返回 false 表示对应 daemon 未通过 install-vmnet-daemons.sh 安装/启动.
    public static func isReady(_ socketPath: String) -> Bool {
        var st = stat()
        guard stat(socketPath, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }
}
