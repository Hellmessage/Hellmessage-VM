// HVMInstall/InstallProgress.swift
// macOS guest 装机过程的进度阶段. CLI/GUI 监听此事件流上报给用户.
// 详见 docs/GUEST_OS_INSTALL.md "安装状态机"

import Foundation

public enum InstallProgress: Sendable, Equatable {
    /// 加载 IPSW + 校验 + 创建 auxiliary
    case preparing
    /// 实际写盘装机, fraction ∈ [0, 1]
    case installing(fraction: Double)
    /// 装机收尾, 写 config.macOS.autoInstalled=true + bootFromDiskOnly=true
    case finalizing
}
