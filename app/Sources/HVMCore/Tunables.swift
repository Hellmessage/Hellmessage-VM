// HVMCore/Tunables.swift
// 后端运行时可调参数集中处. 函数 API 默认参数统一从这里取, 调用方仍可显式覆盖.
// 不收影响功能正确性的实现细节常量 (轮询步长 / ring buffer 等).

import Foundation

/// 各类超时 (秒). 调高让网络/冷启动更宽容, 调低让失败更快暴露.
public enum HVMTimeout {
    /// QMP socket 连接握手超时. QEMU bind/listen 间有窗口, 偶发 ECONNREFUSED 重试.
    public static let qmpConnect: Int = 15

    /// guest serial console chardev socket 等 QEMU listen 就绪的超时
    public static let consoleBridgeConnect: TimeInterval = 5

    /// swtpm 启动后等控制 socket 就绪的超时 (通常 <500ms)
    public static let swtpmSocketReady: TimeInterval = 5

    /// GUI spawn HVM host 子进程后等它拿 BundleLock 的超时 (留余量给 bridged daemon)
    public static let hostStartupLockPoll: Int = 20

    /// 应用退出时优雅停所有 VM 的总超时, 超时后 force kill 残留
    public static let gracefulShutdown: TimeInterval = 10

    /// 应用退出 forceStop 后等 VM 真转 .stopped 的超时, 超时仅 log warning 不阻塞 quit
    public static let forceStopWait: TimeInterval = 5
}

/// 截图与缩略图相关参数.
public enum HVMScreenshot {
    /// hvm-dbg screenshot / agent 用的最长边 (像素), Anthropic many-image 上限 1568
    public static let apiMaxEdge: Int = 1568

    /// VM 列表 thumbnail 的最长边
    public static let thumbnailMaxEdge: Int = 512

    /// thumbnail 抓帧间隔 (秒). 调小耗 CPU, 调大列表画面更滞后
    public static let thumbnailIntervalSec: TimeInterval = 10.0
}
