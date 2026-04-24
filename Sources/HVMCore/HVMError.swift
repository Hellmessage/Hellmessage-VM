// HVMCore/HVMError.swift
// 错误根类型占位. 完整设计见 docs/ERROR_MODEL.md
// M0 只暴露结构, 各子错误的具体 case 随模块实现补齐

import Foundation

/// 全项目错误根类型, 按子系统分派
public enum HVMError: Error, Sendable {
    case bundle(BundleError)
    case storage(StorageError)
    case backend(BackendError)
    case install(InstallError)
    case net(NetError)
    case ipc(IPCError)
    case config(ConfigError)
}

// 以下子错误枚举在 M1+ 各模块内填充具体 case
// 当前仅做类型占位, 避免循环引用

public enum BundleError: Error, Sendable {}
public enum StorageError: Error, Sendable {}
public enum BackendError: Error, Sendable {}
public enum InstallError: Error, Sendable {}
public enum NetError: Error, Sendable {}
public enum IPCError: Error, Sendable {}
public enum ConfigError: Error, Sendable {}

/// 面向用户的错误呈现, GUI ErrorDialog / CLI json / hvm-dbg 共用
public struct UserFacingError: Sendable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: String]
    public let hint: String?

    public init(code: String, message: String, details: [String: String] = [:], hint: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
        self.hint = hint
    }
}
