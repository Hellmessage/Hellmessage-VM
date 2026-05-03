// HVMCore/Tunables.swift
// 后端运行时可调参数集中处. 用户日常可能想调的常量都放这里;
// 函数 API 形态保持默认参数 (`deadlineSec: Int = HVMTimeout.qmpConnect`),
// 调用方仍可显式覆盖, 但默认值统一从这里取.
//
// 不收: 200ms 轮询步长 / ring buffer / read syscall buf — 这些是"调一次定终生"
// 的实现细节, 改它们影响功能正确性, 不属于"调参".
//
// GUI 窗口尺寸不在此 — 那部分依赖 AppKit, 见 HVM/UI/Style/Theme.swift HVMWindow 段.

import Foundation

/// 各类超时 (秒). 调高让网络/冷启动更宽容, 调低让失败更快暴露.
public enum HVMTimeout {
    /// QMP socket 连接握手超时. QEMU bind 与 listen 之间有窗口, 偶发 ECONNREFUSED 重试.
    /// 用在 QemuHostEntry.tryConnectQmp / hvm-dbg qemu-launch.
    public static let qmpConnect: Int = 15

    /// guest serial console (chardev unix socket) 等 QEMU listen 就绪的超时.
    /// 比 QMP 短: console socket 几乎跟 QMP 同时出现, 5s 已很宽松.
    public static let consoleBridgeConnect: TimeInterval = 5

    /// swtpm 启动后等控制 socket 就绪的超时.
    /// swtpm 通常 <500ms; 若 5s 没出 socket 多半是配置或路径错误.
    public static let swtpmSocketReady: TimeInterval = 5

    /// AppModel.start (GUI) spawn HVM host 子进程后等它拿 BundleLock 的超时.
    /// 与 qmpConnect 同一量级 (子进程内部还要起 QMP); 留余量给 bridged + socket_vmnet daemon.
    public static let hostStartupLockPoll: Int = 20

    /// 应用退出时优雅停所有 VM 的总超时. 超时后 force kill 残留.
    public static let gracefulShutdown: TimeInterval = 10

    /// 应用退出时 forceStop 后等 VM 真转 .stopped 的超时.
    /// 超时后只 log warning + 让用户手动 kill (避免 NSApp.terminate 卡死阻塞 quit).
    public static let forceStopWait: TimeInterval = 5
}

/// 截图与缩略图相关参数.
public enum HVMScreenshot {
    /// hvm-dbg screenshot / agent 用的最长边 (像素). Anthropic many-image 上限是 1568.
    /// 调小 = OCR 精度损失; 调大 = 单张 PNG 体积膨胀.
    public static let apiMaxEdge: Int = 1568

    /// VM 列表 thumbnail 的最长边. docs/VM_BUNDLE.md 约定 512.
    public static let thumbnailMaxEdge: Int = 512

    /// thumbnail 抓帧间隔 (秒). VZ + QEMU 后端共用. 调小耗 CPU, 调大列表里看到的画面更滞后.
    public static let thumbnailIntervalSec: TimeInterval = 10.0
}
