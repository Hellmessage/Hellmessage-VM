// HVMQemu/SwtpmArgsBuilder.swift
// 纯函数: 构造 swtpm socket 模式的 argv.
//
// 生命周期: swtpm 在 ctrlSocketPath 监听 → QEMU -chardev 连入 → QEMU 断开后 swtpm --terminate
// 自动退. tpmstate 目录持久化 NV 状态 (Win11 SecureBoot 信任根 + TPM PCR).

import Foundation
import HVMCore

public enum SwtpmArgsBuilder {

    public struct Inputs: Sendable {
        /// TPM NVRAM 持久化目录. 必须可读写, 跨重启保留.
        public let stateDir: URL
        /// QEMU 连接 swtpm 的 unix socket 路径. 不要进 bundle (是 transient).
        public let ctrlSocketPath: String
        /// 调试日志落地; 可选, nil 则 swtpm 不写日志
        public let logFile: URL?
        /// pid 文件; 可选, 用于诊断 / hvm-cli reset-vm 清理
        public let pidFile: URL?
        /// 日志详细度 (1-20). 默认 20 = 全开 (调试期)
        public let logLevel: Int

        public init(
            stateDir: URL,
            ctrlSocketPath: String,
            logFile: URL? = nil,
            pidFile: URL? = nil,
            logLevel: Int = 20
        ) {
            self.stateDir = stateDir
            self.ctrlSocketPath = ctrlSocketPath
            self.logFile = logFile
            self.pidFile = pidFile
            self.logLevel = logLevel
        }
    }

    /// 构造 argv (不含 binary 自身; 调用方喂给 Process.arguments).
    public static func build(_ inputs: Inputs) -> [String] {
        var args: [String] = [
            "socket",
            "--tpm2",                                                   // TPM 2.0 (Win11 必需)
            "--tpmstate", "dir=\(inputs.stateDir.path)",                // NVRAM 持久目录
            "--ctrl",     "type=unixio,path=\(inputs.ctrlSocketPath)",  // QEMU 控制 socket
            "--terminate",                                              // QEMU 断开自动退
            "--flags",    "not-need-init,startup-clear",                // 不强制 host 端初始化
        ]
        if let log = inputs.logFile {
            args += ["--log", "level=\(inputs.logLevel),file=\(log.path)"]
        }
        if let pid = inputs.pidFile {
            args += ["--pid", "file=\(pid.path)"]
        }
        return args
    }
}
