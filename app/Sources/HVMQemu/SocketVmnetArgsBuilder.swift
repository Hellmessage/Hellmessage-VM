// HVMQemu/SocketVmnetArgsBuilder.swift
// 纯函数: 构造 socket_vmnet 启动 argv. 与 SwtpmArgsBuilder 同形态.
//
// 调用方需 sudo (NOPASSWD) 拉起这些 argv. 详见 docs/QEMU_INTEGRATION.md「网络方案」.
//
// QEMU 端对接: 用 -netdev stream,id=net0,addr.type=unix,addr.path=<socketPath>,server=off
// 直接连 socket_vmnet 监听的 unix domain socket. 不走老 socket_vmnet_client fd-passing.

import Foundation
import HVMCore

public enum SocketVmnetArgsBuilder {

    /// vmnet 模式: shared = 类 NAT 但 host 可见 guest; bridged = 跨物理 LAN; host = 仅 host 可达
    public enum VmnetMode: String, Sendable, CaseIterable {
        case shared
        case bridged
        case host
    }

    public struct Inputs: Sendable {
        public let mode: VmnetMode
        /// QEMU 连接 socket_vmnet 的 unix socket (per-VM, transient).
        /// 例: ~/Library/Application Support/HVM/run/<vm-id>.vmnet.sock
        public let socketPath: String
        /// pid 文件; nil 表示不写
        public let pidFile: URL?
        /// bridged 模式必填: 物理网卡名 (en0 等); shared/host 时忽略
        public let bridgedInterface: String?

        public init(
            mode: VmnetMode,
            socketPath: String,
            pidFile: URL? = nil,
            bridgedInterface: String? = nil
        ) {
            self.mode = mode
            self.socketPath = socketPath
            self.pidFile = pidFile
            self.bridgedInterface = bridgedInterface
        }
    }

    public enum BuildError: Error, Sendable, Equatable {
        case bridgedRequiresInterface
    }

    /// 构造 argv (不含 binary 自身; 调用方拼上 sudo + binary 喂给 Process).
    public static func build(_ inputs: Inputs) throws -> [String] {
        var args: [String] = ["--vmnet-mode=\(inputs.mode.rawValue)"]
        if inputs.mode == .bridged {
            guard let iface = inputs.bridgedInterface, !iface.isEmpty else {
                throw BuildError.bridgedRequiresInterface
            }
            args += ["--vmnet-interface=\(iface)"]
        }
        if let pid = inputs.pidFile {
            args += ["--pidfile=\(pid.path)"]
        }
        // 最后一个非选项参数是监听的 socket 路径 (socket_vmnet 约定)
        args += [inputs.socketPath]
        return args
    }
}
