// QemuFanoutSession.swift
//
// 把 QEMU host 子进程暴露的 HDP socket 接到一个**多消费者**扇出器:
// 一个 channel + N 个 subscriber view (主窗口嵌入 + 任意数量独立窗口) 共存.
//
// 跟旧的单消费者 QemuEmbeddedSession 的关键差异:
//   1. fanout 不再 own 单一 view, 改成 weak subscriber 列表
//   2. SURFACE_NEW 拿到的 shm fd 通过 dup() 分发给每个 subscriber 各自 mmap
//      (POSIX shm 同一物理页可多次映射, 跨 view 共享 zero-copy 不冲突)
//   3. 缓存最近一次 SurfaceNew info + 缓存 fd, 让"晚来"的 subscriber (例如用户
//      点 detach 弹出独立窗口时) 立即拿到当前 framebuffer 不等下一帧
//   4. 缓存最近一次 LED 状态, 新 subscriber 即时同步 caps lock 等指示灯
//
// **fd 生命周期**:
//   - SURFACE_NEW 携带的 fd 由 fanout 接管: 第一个活跃 subscriber 拿原 fd
//     (它 mmap + close), 其余 subscriber 拿 dup 的 fd (各自 mmap + close)
//   - fanout 自己 dup 一份保活 (cachedSurfaceFD), 用于以后新 subscriber 加入
//     时再次 dup 给它. 收到下一个 SURFACE_NEW 时关掉旧的 cachedSurfaceFD
//   - fanout 销毁时关掉 cachedSurfaceFD
//
// 输入 (键鼠) 不在 fanout 处理: 每个 FramebufferHostView 自带 InputForwarder,
// 各自连同一个 QMP input socket. macOS NSEvent 默认只送 key window 的 first
// responder, 双 view 共存不会双发事件.

import Foundation
import AppKit
import OSLog
import Darwin
import HVMCore
import HVMBundle
import HVMQemu
import HVMDisplayQemu

private let log = Logger(subsystem: "com.hellmessage.vm", category: "QemuFanout")

@MainActor
final class QemuFanoutSession {

    // MARK: - 公共标识 (新 subscriber 加入时用得上)

    let vmID: UUID
    let bundleURL: URL

    // MARK: - 内部资源

    /// var 而非 let: channel 可在 disconnected 时重建 (例如 guest reset 触发
    /// QEMU iosurface backend 短暂关闭 socket, host 子进程仍在运行 — 这时不该
    /// tearDown fanout, 应当重连 channel 让 view 订阅持续有效).
    private var channel: DisplayChannel
    /// 同 VM 唯一的 InputForwarder (QMP socket 单 client 限制, 不能多 client 并发连).
    /// fanout 启动时 connect 一次, 停止时 disconnect; 多 view (主嵌入 + detached)
    /// 共享同一个实例, 通过 weak 引用注入 view (FramebufferHostView.forwarder).
    /// 每个 view 在 viewCoords 调用前先 setViewSize 同步 view 自己的 size,
    /// NSEvent 一时刻只送一个 view, 序列化无竞争.
    private let forwarder: InputForwarder

    /// spice-vdagent client. user 拖 HVM 主窗口 → resize master view 的
    /// onDrawableSizeChange 调 sendMonitorsConfig(w, h), 直接通过 vdagent
    /// virtio-serial chardev 发 VDAgentMonitorsConfig 给 guest 内 spice-vdagent
    /// 服务 → SetDisplayConfig → 改分辨率. 没装 vdagent 的 guest 不响应没事
    /// (chardev 写穿过去, guest 端没 reader 静默丢, 主路径不阻塞).
    private let vdagent: VdagentClient

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

    /// channel 收到 disconnected 事件 (QEMU host 子进程退出 / GOODBYE / 网络错误)
    /// 时回调. 上层 (AppModel) 用这个回调及时拆 fanout + 关 detached + refresh
    /// list, 否则 detached 窗口会停在最后一帧、主嵌入会黑屏不响应, 直到下次
    /// refreshList 兜底探测 BundleLock. AppModel.ensureQemuFanout 设置该 hook.
    var onDisconnected: (@MainActor () -> Void)?

    private var eventLoopTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var thumbnailTimer: Timer?

    // MARK: - 初始化 / 启动 / 停止

    init(vmID: UUID, bundleURL: URL) {
        self.vmID = vmID
        self.bundleURL = bundleURL
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        let qmpInputPath  = HVMPaths.qmpInputSocketPath(for: vmID).path
        let vdagentPath   = HVMPaths.vdagentSocketPath(for: vmID).path
        self.channel = DisplayChannel(socketPath: iosurfacePath)
        self.forwarder = InputForwarder(qmpSocketPath: qmpInputPath)
        self.vdagent = VdagentClient(socketPath: vdagentPath)
    }

    /// 启动连接 + 事件循环. 不阻塞调用线程. 多次调用安全 (第二次无效).
    func start() {
        guard connectTask == nil else { return }
        log.info("start: retry connecting HDP channel for vm=\(self.vmID.uuidString)")
        forwarder.connect()
        vdagent.connect()
        startThumbnailTimer()
        runConnectLoop()
    }

    /// HDP channel 重连: guest reset 让 QEMU iosurface backend 短暂关 socket 时,
    /// 不能 tearDown fanout (view 订阅会丢, 主嵌入永久黑屏); 应当新建 DisplayChannel
    /// 重新连同一个 socket 路径, view 订阅原样保留, 等新 SURFACE_NEW 到达自然恢复画面.
    private func reconnectChannel() {
        log.info("reconnectChannel: rebuilding channel for vm=\(self.vmID.uuidString)")
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        let iosurfacePath = HVMPaths.iosurfaceSocketPath(for: vmID).path
        self.channel = DisplayChannel(socketPath: iosurfacePath)
        runConnectLoop()
    }

    /// 异步 connect 重试 (最多 5 秒). 成功后启动 eventLoop. start() / reconnectChannel()
    /// 共用. 相同 socket 路径; eventLoop 重启时 self.channel 已是新实例.
    private func runConnectLoop() {
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
            log.error("HDP connect attempts exhausted (5s)")
        }
    }

    /// 停止连接 + 事件循环. 多次调用安全. 不主动通知 subscriber 释放 surface —
    /// view 销毁会自然清掉 renderer 持有的 mmap.
    func stop() {
        thumbnailTimer?.invalidate(); thumbnailTimer = nil
        connectTask?.cancel(); connectTask = nil
        eventLoopTask?.cancel(); eventLoopTask = nil
        channel.disconnect()
        forwarder.disconnect()
        vdagent.disconnect()
        if cachedSurfaceFD >= 0 {
            Darwin.close(cachedSurfaceFD); cachedSurfaceFD = -1
        }
        cachedSurfaceInfo = nil
        cachedLED = nil
    }

    deinit {
        // deinit 跨线程, 不能 call MainActor-isolated 方法.
        // channel.disconnect / forwarder.disconnect / vdagent.disconnect 内部 DispatchQueue 已线程安全.
        channel.disconnect()
        forwarder.disconnect()
        vdagent.disconnect()
        connectTask?.cancel()
        eventLoopTask?.cancel()
        if cachedSurfaceFD >= 0 {
            Darwin.close(cachedSurfaceFD)
        }
    }

    // MARK: - subscriber 管理

    /// 注册一个 view. 若 fanout 已经收到过 SurfaceNew, 立即把当前 surface dup 一份
    /// 喂给这个 view; 同时把当前 LED 状态同步过去.
    /// `isResizeMaster=true` 时 view 的 drawable size 变化会通过 HDP 请求 guest
    /// 改分辨率; false 时忽略 (例如独立窗口 view 拖大不应改 guest 分辨率,
    /// 避免主窗口嵌入 view 跟 detached view 之间反复 resize 拉锯).
    func addSubscriber(_ view: FramebufferHostView, isResizeMaster: Bool) {
        subscribers.removeAll { $0.view == nil || $0.view === view }
        subscribers.append(WeakBox(view))

        // 注入唯一的 forwarder (weak), view 走 NSEvent → forwarder.mouseMove 等.
        view.forwarder = self.forwarder

        // resize master 把自己的 drawable size 推给 guest:
        //   1. channel.requestResize → QEMU patch 0002 RESIZE_REQUEST handler →
        //      dpy_set_ui_info (Linux/Asahi guest 内核 virtio-gpu driver 收 EDID 改分辨率)
        //   2. vdagent.sendMonitorsConfig → 直接通过 vdagent chardev 发
        //      VDAgentMonitorsConfig (Win guest spice-vdagent 服务收 → SetDisplayConfig).
        //      Win 的 ramfb / virtio-gpu driver 不响应 EDID, 必须走这条 spice 协议.
        // 两路并发, guest 哪条 work 哪条生效 (Linux 用 #1, Win 用 #2).
        if isResizeMaster {
            let channel = self.channel
            let vdagent = self.vdagent
            let vmIDStr = self.vmID.uuidString
            view.onDrawableSizeChange = { w, h in
                log.info("FanoutSession[\(vmIDStr)] onDrawableSizeChange \(w)x\(h) → fan out to HDP+vdagent")
                channel.requestResize(width: w, height: h)
                vdagent.sendMonitorsConfig(width: w, height: h)
            }
        } else {
            view.onDrawableSizeChange = nil
        }

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
    }

    /// 显式注销. View 销毁后不调也无所谓 (weak 自然失效), 但显式调可立即释放
    /// fanout 端引用槽位.
    func removeSubscriber(_ view: FramebufferHostView) {
        subscribers.removeAll { $0.view == nil || $0.view === view }
    }

    /// 当前活跃 subscriber 数 (compaction 后). 上层 (AppModel) 用这个判断
    /// 是否还需要保留 fanout: 0 时 + VM 仍 running 时 → tearDown 节省资源.
    var activeSubscriberCount: Int {
        subscribers.removeAll { $0.view == nil }
        return subscribers.compactMap { $0.view }.count
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

    /// 借用任意一个 alive subscriber 的 renderer 抓 CGImage; 全部空时跳过本 tick.
    /// 各 subscriber 的 renderer 内容相同 (映射同一份 shm), 借任一个均可.
    private func captureThumbnail() {
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
        // 高频 surfaceDamage 不能在 MainActor 上吃, 否则 30Hz draw 调度会被 starve.
        // 跟旧实现一致: 事件循环跑在默认 actor, 状态更新切回 MainActor.
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
                case .cursorDefine, .cursorPos:
                    break
                case .disconnected(let reason):
                    log.info("event disconnected reason=\(String(describing: reason))")
                    // 关键判断: host 子进程是否仍持 BundleLock.
                    //   busy=true: QEMU 进程还在跑 (例如 Win guest 触发 ACPI reset,
                    //     iosurface backend 短暂关 socket 重新初始化) — 重连 channel,
                    //     view 订阅保留, 等新 SURFACE_NEW 自然恢复, 不 tearDown.
                    //   busy=false: host 子进程退出 (QEMU exit / panic) — 真 stopped,
                    //     onDisconnected 走 AppModel.tearDownQemuFanout + refreshList.
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
    /// 第一个 subscriber 拿原 fd, 其余 dup; fanout 自己再 dup 一份缓存供后续
    /// addSubscriber replay 使用 (替换并关闭老缓存 fd).
    private func broadcastSurface(_ arrival: DisplayChannel.SurfaceArrival) {
        let alive = subscribers.compactMap { $0.view }

        // 关旧缓存, 用新 fd 重新 dup 一份缓存
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

        if alive.isEmpty {
            // 没人接, 关掉原 fd 防泄漏 (cache 已 dup 一份, 不影响以后 replay)
            Darwin.close(arrival.shmFD)
            return
        }

        // 第一个 subscriber 拿原 fd, 其余各 dup 一份各自 mmap
        for (idx, view) in alive.enumerated() {
            let fd: Int32
            if idx == 0 {
                fd = arrival.shmFD
            } else {
                let d = Darwin.dup(arrival.shmFD)
                if d < 0 {
                    log.error("broadcastSurface: dup for subscriber \(idx) failed errno=\(errno)")
                    continue
                }
                fd = d
            }
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
