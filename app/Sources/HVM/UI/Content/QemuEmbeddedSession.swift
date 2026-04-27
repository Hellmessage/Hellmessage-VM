// QemuEmbeddedSession.swift
//
// 把 QEMU host 子进程暴露的 HDP / 输入 QMP 两条 socket 连起来, 组装出
// 嵌入主窗口右栏的 FramebufferHostView. 跟 VZ 通路的 HVMSession (HVMDisplay)
// 平行存在, 但没有本进程 VZVirtualMachine 实例 — QEMU 的虚拟机进程在 host
// 子进程里, 主 GUI 只通过两条 socket 拉显示 + 推输入.
//
// 生命周期:
//   1. init(bundleURL): 计算 socket 路径, 不连接任何东西
//   2. start(): 异步 retry connect HDP socket (QEMU listener 启动有时延);
//      connect 成功后启动 events loop, 同步开始接收 framebuffer / 光标 /
//      LED 状态, 同时建立 input QMP 连接
//   3. stop(): 异步 disconnect 两条 socket, 停 events loop
//
// 注: socket race 处理 — QEMU 子进程从 fork 到 listener pthread accept 大约
// 50ms~1s, 期间 connect() 会失败. retry 50 次 × 100ms = 5 秒, 应该够用.

import Foundation
import AppKit
import HVMCore
import HVMDisplayQemu

@MainActor
final class QemuEmbeddedSession {

    let view: FramebufferHostView
    private let channel: DisplayChannel
    private let forwarder: InputForwarder

    private var eventLoopTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(vmID: UUID) {
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        let qmpInputPath  = HVMPaths.qmpInputSocketPath(for: vmID).path

        self.view      = FramebufferHostView(frame: .zero)
        self.channel   = DisplayChannel(socketPath: iosurfacePath)
        self.forwarder = InputForwarder(qmpSocketPath: qmpInputPath)
        self.view.inputForwarder = forwarder
    }

    /// 启动连接 + 事件循环. 不阻塞调用线程.
    func start() {
        forwarder.connect()

        // HDP socket 可能未就绪 (QEMU 还没 bind listener), 重试连接.
        let channel = self.channel
        connectTask = Task.detached(priority: .userInitiated) { [weak self] in
            for _ in 0..<50 {
                do {
                    try channel.connect()
                    await MainActor.run { self?.startEventLoop() }
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                }
            }
            // 5 秒仍失败, 写到 stderr; UI 留 view 空白 (黑屏), 用户可重试 stop/start
            FileHandle.standardError.write(Data(
                "QemuEmbeddedSession: HDP connect timed out after 5s\n".utf8))
        }
    }

    /// 停止连接 + 事件循环. 多次调用安全.
    func stop() {
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        channel.disconnect()
        forwarder.disconnect()
    }

    deinit {
        // deinit 在主线程或其它线程都可能, 不能 call MainActor-isolated 方法.
        // channel/forwarder 各自的 disconnect 是线程安全 (内部 DispatchQueue).
        channel.disconnect()
        forwarder.disconnect()
        connectTask?.cancel()
        eventLoopTask?.cancel()
    }

    // MARK: - private

    private func startEventLoop() {
        let stream = channel.events
        eventLoopTask = Task { [weak view] in
            for await event in stream {
                guard let view = view else { return }
                switch event {
                case .surfaceNew(let arrival):
                    view.bindSurface(arrival)
                case .ledState(let leds):
                    view.updateGuestLEDState(leds)
                case .helloDone,
                     .surfaceDamage,
                     .cursorDefine,
                     .cursorPos:
                    // helloDone 不需处理; damage 我们用全屏 shader 重绘, 也不必逐区
                    // (Phase 5 性能调优时可以加局部 invalidate). cursor 系列暂走 host
                    // 系统光标 (NSCursor.hide on enter); 后期可加自绘硬件光标层.
                    break
                case .disconnected:
                    return
                }
            }
        }
    }
}
