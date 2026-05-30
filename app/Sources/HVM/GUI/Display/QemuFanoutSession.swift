// QemuFanoutSession.swift — 把 QEMU host 子进程的 HDP socket 接到多消费者扇出器:
// 一个 channel + N 个 subscriber view (主窗口嵌入 + 任意数量独立窗口) 共存, weak subscriber 列表.
//
// SURFACE_NEW 拿到的 shm fd 通过 dup() 分发给每个 subscriber 各自 mmap (POSIX shm 同物理页可多次映射,
// zero-copy 不冲突). 缓存最近 SurfaceNew info + fd + LED + cursor, 让"晚来"的 subscriber 立即拿当前画面.
//
// **fd 生命周期**: SURFACE_NEW 的 fd 由 fanout 接管, 每个 subscriber 各 dup 一份 (mmap + close),
// fanout 自留一份 cachedSurfaceFD 供后续新 subscriber dup; 换帧 / 销毁时关旧 fd.
//
// 输入 (键鼠) 不在 fanout 处理: 每个 view 自带 InputForwarder 连同一 QMP input socket;
// macOS NSEvent 只送 key window first responder, 双 view 共存不双发.

import Foundation
import AppKit
import OSLog
import Darwin
import HVMCore
import HVMBundle
import HVMQemu
import HVMDisplayQemu
import HVMIPC

private let log = Logger(subsystem: "com.hellmessage.vm", category: "QemuFanout")

@MainActor
final class QemuFanoutSession {

    // MARK: - 公共标识 (新 subscriber 加入时用得上)

    let vmID: UUID
    let bundleURL: URL

    // MARK: - 内部资源

    /// var 而非 let: channel 可在 disconnected 时重建 (guest reset 时 iosurface backend 短暂关 socket,
    /// host 子进程仍在跑 — 不该 tearDown fanout, 应重连 channel 让 view 订阅持续有效).
    private var channel: DisplayChannel
    /// 同 VM 唯一的 InputForwarder (QMP socket 单 client 限制). 多 view 共享同一实例 (weak 注入 view),
    /// NSEvent 一时刻只送一个 view, 序列化无竞争.
    private let forwarder: InputForwarder

    /// 弱引用包. View 销毁后 fanout 自动跳过 (不需要显式 unsubscribe 也安全).
    private final class WeakBox {
        weak var view: FramebufferHostView?
        init(_ v: FramebufferHostView) { self.view = v }
    }
    private var subscribers: [WeakBox] = []

    /// 当前 surface 几何 + dup 的 fd 缓存. 仅 fanout 内部持有, deinit/换帧时关闭.
    private var cachedSurfaceInfo: HDP.SurfaceNew?
    private var cachedSurfaceFD: Int32 = -1

    /// 当前 LED 状态. 新 subscriber 加入立即下发, 防止 caps 指示灯滞后一拍.
    private var cachedLED: HDP.LedState?

    /// 最近 hardware cursor 数据, 新 subscriber 加入时 replay 防 detached 窗口光标隐形.
    /// CURSOR_DEFINE 推 BGRA pixels + hot spot; CURSOR_POS 推 visible flag (x/y 不用, host↔guest tablet 1:1).
    private var cachedCursorDefine: HDP.CursorDefine?
    private var cachedCursorPos: HDP.CursorPos?

    /// channel disconnected (子进程退出 / GOODBYE / 网络错误) 回调. 上层及时拆 fanout + 关 detached + refresh.
    var onDisconnected: (@MainActor () -> Void)?

    private var eventLoopTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var thumbnailTimer: Timer?

    /// resize debounce: 拖动期间高频触发不立即下发, 用户停 300ms 后才推一次 RESIZE_REQUEST + MonitorsConfig.
    private var pendingResizeWorkItem: DispatchWorkItem?
    private static let resizeDebounceSeconds: Double = 0.3

    // MARK: - 初始化 / 启动 / 停止

    init(vmID: UUID, bundleURL: URL) {
        self.vmID = vmID
        self.bundleURL = bundleURL
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        let qmpInputPath  = HVMPaths.qmpInputSocketPath(for: vmID).path
        self.channel = DisplayChannel(socketPath: iosurfacePath)
        self.forwarder = InputForwarder(qmpSocketPath: qmpInputPath)
    }

    /// 启动连接 + 事件循环. 不阻塞调用线程, 多次调用安全.
    /// vdagent socket 由 VMHost 持久 own (single-client), GUI 不直连; resize 走 IPC display.setMonitors.
    func start() {
        guard connectTask == nil else { return }
        log.info("start: retry connecting HDP channel for vm=\(self.vmID.uuidString)")
        forwarder.connect()
        startThumbnailTimer()
        runConnectLoop()
    }

    /// HDP channel 重连: guest reset 时不 tearDown fanout (会丢 view 订阅 → 主嵌入永久黑屏),
    /// 而是新建 DisplayChannel 重连同一 socket, view 订阅保留, 等新 SURFACE_NEW 自然恢复.
    private func reconnectChannel() {
        log.info("reconnectChannel: rebuilding channel for vm=\(self.vmID.uuidString)")
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        self.channel = DisplayChannel(socketPath: iosurfacePath)
        runConnectLoop()
    }

    /// 异步 connect 重试 (最多 60 秒, 600 × 100ms), 成功后启动 eventLoop. start() / reconnectChannel() 共用.
    /// 60s 窗口给加密 VM 冷启动 (PBKDF2 解锁 + LUKS + swtpm + QEMU init 可能 20s+); 明文 VM 通常 1-2s.
    private func runConnectLoop() {
        let channel = self.channel
        connectTask = Task.detached(priority: .userInitiated) { [weak self] in
            for attempt in 0..<600 {
                do {
                    try channel.connect()
                    log.info("HDP channel connect OK on attempt \(attempt)")
                    await MainActor.run { self?.startEventLoop() }
                    return
                } catch {
                    if attempt == 0 || attempt == 50 || attempt == 200 {
                        log.info("HDP connect attempt \(attempt) failed: \(String(describing: error))")
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { return }
                }
            }
            log.error("HDP connect attempts exhausted (60s)")
        }
    }

    /// 停止连接 + 事件循环. 多次调用安全. 不主动通知 subscriber 释放 surface —
    /// view 销毁会自然清掉 renderer 持有的 mmap.
    func stop() {
        thumbnailTimer?.invalidate(); thumbnailTimer = nil
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        pendingResizeWorkItem?.cancel(); pendingResizeWorkItem = nil
        channel.disconnect()
        forwarder.disconnect()
        if cachedSurfaceFD >= 0 {
            Darwin.close(cachedSurfaceFD); cachedSurfaceFD = -1
        }
        cachedSurfaceInfo = nil
        cachedLED = nil
    }

    deinit {
        // deinit 跨线程, 不能 call MainActor-isolated 方法.
        // channel.disconnect / forwarder.disconnect 内部 DispatchQueue 已线程安全.
        channel.disconnect()
        forwarder.disconnect()
        connectTask?.cancel()
        eventLoopTask?.cancel()
        if cachedSurfaceFD >= 0 {
            Darwin.close(cachedSurfaceFD)
        }
    }

    // MARK: - subscriber 管理

    /// 注册一个 view. 若已收过 SurfaceNew, 立即 dup 当前 surface + replay LED/cursor 给它.
    /// isResizeMaster 字段保留 (语义: 当前 view 是否 resize 决策者), 实际 resize 走 windowDidEndLiveResize.
    func addSubscriber(_ view: FramebufferHostView, isResizeMaster: Bool) {
        subscribers.removeAll { $0.view == nil || $0.view === view }
        subscribers.append(WeakBox(view))

        // 注入唯一的 forwarder (weak), view 走 NSEvent → forwarder.mouseMove 等.
        view.forwarder = self.forwarder

        // resize 不绑 view.onDrawableSizeChange (任何 layout 微调都会盲发 resize 请求改 guest 分辨率);
        // 只在用户真正拖窗口结束 (windowDidEndLiveResize) 时由调用方主动调 fanout.scheduleResize.
        view.onDrawableSizeChange = nil
        _ = isResizeMaster

        // replay 当前 surface (如果已有)
        if let info = cachedSurfaceInfo, cachedSurfaceFD >= 0 {
            let dup = Darwin.dup(cachedSurfaceFD)
            if dup >= 0 {
                let arrival = DisplayChannel.SurfaceArrival(info: info, shmFD: dup)
                view.bindSurface(arrival)
                view.markFramebufferDirty()
            } else {
                log.error("addSubscriber: dup cachedSurfaceFD failed errno=\(errno)")
            }
        }
        if let leds = cachedLED {
            view.updateGuestLEDState(leds)
        }
        if let def = cachedCursorDefine {
            view.applyGuestCursorDefine(def)
        }
        if let pos = cachedCursorPos {
            view.applyGuestCursorPos(pos)
        }
    }

    /// 显式注销. View 销毁后不调也无所谓 (weak 自然失效), 但显式调可立即释放
    /// fanout 端引用槽位.
    func removeSubscriber(_ view: FramebufferHostView) {
        subscribers.removeAll { $0.view == nil || $0.view === view }
    }

    /// 用户主动触发 resize (NSWindow live resize 结束). 调用方: DetachedVMWindowController
    /// 的 windowDidEndLiveResize. 对外入口, internal 可见.
    @MainActor
    func requestResizeFromUser(width: UInt32, height: UInt32) {
        scheduleResize(width: width, height: height)
    }

    /// resize 防抖入口. 真正下发由 main queue timer 触发, 双通路:
    ///   1) HDP RESIZE_REQUEST — 直连 iosurface socket (Linux virtio-gpu 走这条)
    ///   2) IPC display.setMonitors → VMHost vdagent.sendMonitorsConfig (Win spice-vdagent 走这条)
    /// IPC 走 background queue 防 main 阻塞; 失败 silent.
    /// dedup: 跟 cachedSurfaceInfo 一致 / 没收过 SURFACE_NEW 都跳过 (不知 guest 状态不盲发).
    @MainActor
    private func scheduleResize(width: UInt32, height: UInt32) {
        // dedup: 跟当前 guest framebuffer 一致 → 跳过
        if let info = cachedSurfaceInfo, info.width == width, info.height == height {
            return
        }
        // 没收过 SURFACE_NEW → 不知 guest 当前 size → 不轻易发
        guard cachedSurfaceInfo != nil else {
            log.info("scheduleResize \(width)x\(height) skipped: no cachedSurfaceInfo (waiting first SURFACE_NEW)")
            return
        }
        pendingResizeWorkItem?.cancel()
        let channel = self.channel
        let bundleURL = self.bundleURL
        let vmIDStr = self.vmID.uuidString
        let item = DispatchWorkItem {
            log.info("FanoutSession[\(vmIDStr)] resize debounced \(width)x\(height) → HDP + IPC")
            channel.requestResize(width: width, height: height)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.ipcSetMonitors(bundleURL: bundleURL, width: width, height: height)
            }
        }
        pendingResizeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resizeDebounceSeconds, execute: item)
    }

    /// 后台线程调: BundleLock.inspect 取 socket → SocketClient.request display.setMonitors.
    /// 任一步失败 silent log.warn — vdagent 通道挂了不该让 GUI 卡或弹错.
    nonisolated private static func ipcSetMonitors(bundleURL: URL, width: UInt32, height: UInt32) {
        guard let holder = BundleLock.inspect(bundleURL: bundleURL),
              !holder.socketPath.isEmpty else {
            log.warning("FanoutSession resize: BundleLock.inspect 失败, 跳过 IPC")
            return
        }
        let req = IPCRequest(
            op: IPCOp.displaySetMonitors.rawValue,
            args: ["width": "\(width)", "height": "\(height)"]
        )
        do {
            let resp = try SocketClient.request(socketPath: holder.socketPath, request: req, timeoutSec: 3)
            if !resp.ok {
                log.warning("FanoutSession resize IPC failed: \(resp.error?.message ?? "?")")
            }
        } catch {
            log.warning("FanoutSession resize IPC error: \(String(describing: error))")
        }
    }

    /// 当前活跃 subscriber 数 (compaction 后). 上层据此判断是否保留 fanout (0 + running → tearDown 省资源).
    var activeSubscriberCount: Int {
        subscribers.removeAll { $0.view == nil }
        return subscribers.compactMap { $0.view }.count
    }

    /// 当前 guest framebuffer 像素尺寸 (cachedSurfaceInfo 的 width/height).
    /// 独立窗口打开时用来按 guest 分辨率定 contentSize, fanout 还没收到首帧时返 nil.
    var currentGuestPixelSize: CGSize? {
        guard let info = cachedSurfaceInfo, info.width > 0, info.height > 0 else {
            return nil
        }
        return CGSize(width: Int(info.width), height: Int(info.height))
    }

    // MARK: - thumbnail

    private func startThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = Timer.scheduledTimer(
            withTimeInterval: HVMScreenshot.thumbnailIntervalSec,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.captureThumbnail() }
        }
    }

    /// 借任一 alive subscriber 的 renderer 抓 CGImage (各 renderer 映射同一份 shm, 内容相同); 全空跳过本 tick.
    private func captureThumbnail() {
        // 缩略图开关关闭 → 跳过. 每 tick 读 (非启动时拍板), 切换 toggle 立即生效.
        guard ThumbnailPreferences.readEnabledFromDefaults() else { return }
        guard let view = subscribers.lazy.compactMap({ $0.view }).first,
              let cg = view.renderer.snapshotCGImage() else { return }
        let bundle = self.bundleURL
        let maxEdge = HVMScreenshot.thumbnailMaxEdge
        Task.detached(priority: .background) {
            let scaled = PPMReader.downscale(cg, maxEdge: maxEdge)
            guard let png = PPMReader.encodePNG(scaled) else { return }
            try? ThumbnailWriter.writeAtomic(png, to: bundle)
        }
    }

    // MARK: - 事件循环 / 扇出

    private func startEventLoop() {
        let stream = channel.events
        // 事件循环跑在默认 actor (高频 surfaceDamage 不能在 MainActor 上吃, 否则 starve 30Hz draw),
        // 状态更新切回 MainActor.
        eventLoopTask = Task { [weak self] in
            log.info("event loop started")
            for await event in stream {
                guard let self else { return }
                switch event {
                case .helloDone(let caps):
                    log.info("event helloDone caps=0x\(String(caps.rawValue, radix: 16))")
                case .surfaceNew(let arrival):
                    log.info("event surfaceNew \(arrival.info.width)x\(arrival.info.height) stride=\(arrival.info.stride) shm_size=\(arrival.info.shmSize) fd=\(arrival.shmFD)")
                    await MainActor.run { self.broadcastSurface(arrival) }
                case .surfaceDamage:
                    await MainActor.run { self.broadcastDamage() }
                case .ledState(let leds):
                    log.info("event ledState caps=\(leds.capsLock) num=\(leds.numLock) scroll=\(leds.scrollLock)")
                    await MainActor.run { self.broadcastLED(leds) }
                case .cursorDefine(let def):
                    await MainActor.run {
                        self.cachedCursorDefine = def
                        for box in self.subscribers {
                            box.view?.applyGuestCursorDefine(def)
                        }
                    }
                case .cursorPos(let pos):
                    await MainActor.run {
                        self.cachedCursorPos = pos
                        for box in self.subscribers {
                            box.view?.applyGuestCursorPos(pos)
                        }
                    }
                case .disconnected(let reason):
                    log.info("event disconnected reason=\(String(describing: reason))")
                    // 按 BundleLock.isBusy 分流: busy=true (QEMU 还在跑, 如 ACPI reset) → 重连 channel 保留订阅;
                    // busy=false (子进程退出) → 真 stopped, onDisconnected 走 tearDown + refreshList.
                    await MainActor.run {
                        let stillBusy = BundleLock.isBusy(bundleURL: self.bundleURL)
                        log.info("disconnected: BundleLock.isBusy=\(stillBusy)")
                        if stillBusy {
                            self.reconnectChannel()
                        } else {
                            self.onDisconnected?()
                        }
                    }
                    return
                }
            }
            log.info("event loop ended (stream finished)")
        }
    }

    /// 把新到达的 SurfaceArrival fan-out 给所有 alive subscriber.
    /// 必须先一次性 dup 出所有 fd 再分发: 否则第一个 view.bindSurface 内 mmap 后 close 原 fd,
    /// 后续 dup(arrival.shmFD) 全部 EBADF. 统一: cache + 每 subscriber 各 dup, 最后 close 原 fd.
    private func broadcastSurface(_ arrival: DisplayChannel.SurfaceArrival) {
        let alive = subscribers.compactMap { $0.view }

        // 关旧缓存, dup 一份新 fd 进 cache (供后续 addSubscriber replay)
        if cachedSurfaceFD >= 0 {
            Darwin.close(cachedSurfaceFD); cachedSurfaceFD = -1
        }
        let cacheDup = Darwin.dup(arrival.shmFD)
        if cacheDup >= 0 {
            cachedSurfaceFD = cacheDup
            cachedSurfaceInfo = arrival.info
        } else {
            log.error("broadcastSurface: dup for cache failed errno=\(errno)")
            cachedSurfaceInfo = nil
        }

        // 给每个 subscriber 提前 dup 一份独立 fd (分发前全部 dup 完)
        var subFds: [Int32] = []
        subFds.reserveCapacity(alive.count)
        for _ in alive {
            let d = Darwin.dup(arrival.shmFD)
            if d < 0 {
                log.error("broadcastSurface: dup for subscriber failed errno=\(errno)")
            }
            subFds.append(d)
        }
        // 原 fd 已不再用 (cache + N 个 subscriber 各持独立 dup), close 防泄漏
        Darwin.close(arrival.shmFD)

        for (view, fd) in zip(alive, subFds) {
            if fd < 0 { continue }
            let copy = DisplayChannel.SurfaceArrival(info: arrival.info, shmFD: fd)
            view.bindSurface(copy)
        }
    }

    private func broadcastDamage() {
        for box in subscribers {
            box.view?.markFramebufferDirty()
        }
    }

    private func broadcastLED(_ leds: HDP.LedState) {
        cachedLED = leds
        for box in subscribers {
            box.view?.updateGuestLEDState(leds)
        }
    }
}
