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
import OSLog
import HVMCore
import HVMBundle
import HVMQemu
import HVMDisplayQemu

private let log = Logger(subsystem: "com.hellmessage.vm", category: "QemuEmbed")

@MainActor
final class QemuEmbeddedSession {

    let view: FramebufferHostView
    private let channel: DisplayChannel
    private let forwarder: InputForwarder
    private let bundleURL: URL

    private var eventLoopTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var thumbnailTimer: Timer?

    init(vmID: UUID, bundleURL: URL) {
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        let qmpInputPath  = HVMPaths.qmpInputSocketPath(for: vmID).path

        self.bundleURL = bundleURL
        self.view      = FramebufferHostView(frame: .zero)
        self.channel   = DisplayChannel(socketPath: iosurfacePath)
        self.forwarder = InputForwarder(qmpSocketPath: qmpInputPath)
        self.view.inputForwarder = forwarder
        // drawable 尺寸变化 → 通过 HDP RESIZE_REQUEST 让 guest 改分辨率.
        // host 不知道 guest 是否装了 vdagent, 不管装没装都发 — 没装时 QEMU
        // 端 dpy_set_ui_info 仍触发 EDID 变化但 guest 内 X / Wayland 不会自动响应,
        // 行为退化但不报错.
        let channel = self.channel
        self.view.onDrawableSizeChange = { w, h in
            channel.requestResize(width: w, height: h)
        }
    }

    /// 启动连接 + 事件循环. 不阻塞调用线程.
    func start() {
        log.info("start: connecting forwarder + retry channel")
        forwarder.connect()
        startThumbnailTimer()

        // HDP socket 可能未就绪 (QEMU 还没 bind listener), 重试连接.
        let channel = self.channel
        connectTask = Task.detached(priority: .userInitiated) { [weak self] in
            for attempt in 0..<50 {
                do {
                    try channel.connect()
                    log.info("HDP channel connect OK on attempt \(attempt)")
                    await MainActor.run { self?.startEventLoop() }
                    return
                } catch {
                    if attempt == 0 || attempt == 10 {
                        log.info("HDP connect attempt \(attempt) failed: \(String(describing: error))")
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                }
            }
            log.error("HDP connect timed out after 5s")
        }
    }

    /// 停止连接 + 事件循环. 多次调用安全.
    func stop() {
        thumbnailTimer?.invalidate(); thumbnailTimer = nil
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        channel.disconnect()
        forwarder.disconnect()
    }

    deinit {
        // deinit 在主线程或其它线程都可能, 不能 call MainActor-isolated 方法.
        // channel/forwarder 各自的 disconnect 是线程安全 (内部 DispatchQueue).
        // thumbnailTimer 必须在 main 上 invalidate, 这里靠 stop() 提前调过 (defensive).
        channel.disconnect()
        forwarder.disconnect()
        connectTask?.cancel()
        eventLoopTask?.cancel()
    }

    // MARK: - thumbnail (zero-copy 路径, 不走 QMP screendump)

    /// 启动 10s 间隔 thumbnail 抓帧. 直接从 renderer 的 bytesNoCopy MTLBuffer
    /// 读 framebuffer (mmap 共享内存, 0 拷贝), bg thread 编 PNG → 写
    /// bundle/meta/thumbnail.png. 跟 QEMU iothread 完全解耦, 不暂停 guest.
    private func startThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = Timer.scheduledTimer(
            withTimeInterval: HVMScreenshot.thumbnailIntervalSec,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.captureThumbnail()
            }
        }
    }

    /// main 上拿 CGImage (CGDataProvider 持 buffer 引用, 之后 bg 线程访问安全),
    /// 然后 detach 到 bg 做 downscale + PNG encode + 落盘.
    private func captureThumbnail() {
        guard let cg = view.renderer.snapshotCGImage() else { return }
        let bundle = self.bundleURL
        let maxEdge = HVMScreenshot.thumbnailMaxEdge
        Task.detached(priority: .background) {
            let scaled = PPMReader.downscale(cg, maxEdge: maxEdge)
            guard let png = PPMReader.encodePNG(scaled) else { return }
            try? ThumbnailWriter.writeAtomic(png, to: bundle)
        }
    }

    // MARK: - private

    private func startEventLoop() {
        let stream = channel.events
        // 事件循环留在 bg actor 跑, 只把改 NSView/renderer 状态的事件 (surfaceNew /
        // ledState) 通过 await MainActor.run 切到 main. 整个 task 都 @MainActor 会让
        // 高频 surfaceDamage (bootmgfw / Win Setup 每次 BLT 都触发) starve main thread,
        // draw(in:) 30Hz timer 调度不上 → 实测卡到 ~1帧/10秒.
        eventLoopTask = Task { [weak view] in
            log.info("event loop started")
            for await event in stream {
                guard let view = view else {
                    log.info("event loop: view dropped, exit")
                    return
                }
                switch event {
                case .helloDone(let caps):
                    log.info("event helloDone caps=0x\(String(caps.rawValue, radix: 16))")
                case .surfaceNew(let arrival):
                    log.info("event surfaceNew \(arrival.info.width)x\(arrival.info.height) stride=\(arrival.info.stride) shm_size=\(arrival.info.shmSize) fd=\(arrival.shmFD)")
                    await MainActor.run { view.bindSurface(arrival) }
                    log.info("surface bound to renderer")
                case .surfaceDamage(let d):
                    log.debug("event surfaceDamage \(d.x),\(d.y) \(d.w)x\(d.h)")
                    // Manual draw 模式: 每次 damage 都标 dirty 触发 draw. setNeedsDisplay
                    // idempotent + AppKit 自动合并到下一帧, 高频 damage 不会爆 main runloop.
                    await MainActor.run { view.markFramebufferDirty() }
                case .ledState(let leds):
                    log.info("event ledState caps=\(leds.capsLock) num=\(leds.numLock) scroll=\(leds.scrollLock)")
                    await MainActor.run { view.updateGuestLEDState(leds) }
                case .cursorDefine, .cursorPos:
                    break
                case .disconnected(let reason):
                    log.info("event disconnected reason=\(String(describing: reason))")
                    return
                }
            }
            log.info("event loop ended (stream finished)")
        }
    }
}
