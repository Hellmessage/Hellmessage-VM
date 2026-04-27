// HVMQemu/VmnetDaemonPaths.swift
// socket_vmnet 系统级 daemon socket 路径常量.
//
// 架构: socket_vmnet 由 launchd 以 root 拉起 (scripts/install-vmnet-helper.sh 安装),
// 监听固定 unix socket. QEMU 通过 -netdev stream,addr.path=... 连过来即可.
// 不再 per-VM spawn sidecar (老方案 sudoers NOPASSWD 已废弃, 见 CLAUDE.md).
//
// 路径约定 (与 socket_vmnet 上游 + lima/HellVM 对齐):
//   /var/run/socket_vmnet              ← shared
//   /var/run/socket_vmnet.host         ← host
//   /var/run/socket_vmnet.bridged.<iface>  ← bridged en0 / en1 / ...

import Foundation

public enum VmnetDaemonPaths {
    /// 测试用 env override: 改 socket 父目录, 默认 /var/run.
    /// 仅供 swift test 跳过 sudo 拉 launchd daemon 的依赖, 生产路径不该设此 env.
    public static let socketDirEnvVar = "HVM_VMNET_SOCKET_DIR"

    public static var socketDir: String {
        ProcessInfo.processInfo.environment[socketDirEnvVar] ?? "/var/run"
    }

    public static var sharedSocket: String { "\(socketDir)/socket_vmnet" }
    public static var hostSocket: String   { "\(socketDir)/socket_vmnet.host" }

    public static func bridgedSocket(interface: String) -> String {
        "\(socketDir)/socket_vmnet.bridged.\(interface)"
    }

    /// 检测 daemon socket 是否就绪 (文件存在 + 是 unix socket).
    /// 返回 false 表示对应 daemon 未通过 install-vmnet-helper.sh 安装/启动.
    public static func isReady(_ socketPath: String) -> Bool {
        var st = stat()
        guard stat(socketPath, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }
}
