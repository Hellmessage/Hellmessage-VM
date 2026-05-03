// HVMDisplayQemu/PasteboardBridge.swift
//
// macOS NSPasteboard ↔ guest 剪贴板 双向同步桥. 仅 UTF-8 文本.
//
// 工作流:
//   - host → guest:
//       1Hz Timer 轮询 NSPasteboard.general.changeCount
//       检测到变化 → 读 NSPasteboard.string(.string) → vdagent.sendClipboardText(text)
//       VdagentClient 内部走 GRAB → 等 guest REQUEST → 发 CLIPBOARD 数据
//
//   - guest → host:
//       VdagentClient.onClipboardTextReceived 回调 → NSPasteboard 写 string
//       记录 lastWrittenChangeCount, 下次轮询比对避免 echo (host 写完导致 changeCount +1,
//       不能再当成 host 端用户复制反推回 guest)
//
// 没有事件 API, NSPasteboard 只能轮询 — 跟 UTM (UTMPasteboard 1Hz Timer) 一致.
//
// 启停由外部控制 (Pasteboard 状态可在运行中切换):
//   - start(): 起 Timer + 注册 vdagent 回调
//   - stop():  停 Timer + 摘掉回调 + 通知 guest CLIPBOARD_RELEASE
//
// 设计要点:
//   - 不持有 vdagent 强引用 — vdagent 是 VMHost 进程级 singleton, bridge 只是 view 层
//   - 启动时 *不* 把当前 host 剪贴板推 guest — 那会让"用户启动 VM 时 host 上恰好有
//     不相关内容"也被同步, 行为不直观. 用户复制一次以后才同步.

import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.hellmessage.vm", category: "Pasteboard")

@MainActor
public final class PasteboardBridge {

    private let vdagent: VdagentClient
    private weak var pasteboard: NSPasteboard?
    private var pollTimer: Timer?

    /// NSPasteboard 上一次见到的 changeCount. 启动时取当前值, 第一次 tick 不会立刻同步.
    private var lastObservedChangeCount: Int = 0
    /// 我们刚写入 pasteboard 后的 changeCount, 用来排除 echo.
    private var lastWrittenChangeCount: Int = 0

    private var enabled: Bool = false

    /// `pasteboard` 默认走 .general (用户系统剪贴板), 测试可注入 mock.
    public init(vdagent: VdagentClient, pasteboard: NSPasteboard = .general) {
        self.vdagent = vdagent
        self.pasteboard = pasteboard
    }

    /// 起 Timer + 注册 vdagent 回调. 已 enabled 时无副作用.
    public func start() {
        guard !enabled else { return }
        enabled = true
        guard let pb = pasteboard else { return }
        lastObservedChangeCount = pb.changeCount
        log.info("PasteboardBridge start (initial changeCount=\(self.lastObservedChangeCount))")

        // 注册 vdagent → host 回调. callback 在 vdagent 内部 queue 上, 切到 main.
        vdagent.onClipboardTextReceived = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.applyGuestText(text)
            }
        }

        // 1Hz Timer 走 RunLoop.main, 与 UTM 一致. tolerance 0.2s 节能.
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollHostPasteboard() }
        }
        t.tolerance = 0.2
        pollTimer = t
    }

    /// 停 Timer + 摘回调. 通知 guest 我们的 host clipboard 已离场 (RELEASE).
    public func stop() {
        guard enabled else { return }
        enabled = false
        log.info("PasteboardBridge stop")
        pollTimer?.invalidate(); pollTimer = nil
        vdagent.onClipboardTextReceived = nil
        vdagent.sendClipboardRelease()
    }

    public var isEnabled: Bool { enabled }

    /// 运行中切换. true → start; false → stop.
    public func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    // MARK: - host → guest

    private func pollHostPasteboard() {
        guard enabled, let pb = pasteboard else { return }
        let cur = pb.changeCount
        guard cur != lastObservedChangeCount else { return }
        lastObservedChangeCount = cur

        // 排除 echo: 如果是我们自己刚写入触发的, 不再回推
        if cur == lastWrittenChangeCount {
            return
        }

        // 只关心 string. 其他类型 (图片 / 文件) 暂不支持.
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            // 用户清空了 host pasteboard / 复制了非文本 — 通知 guest release
            vdagent.sendClipboardRelease()
            return
        }
        log.info("PasteboardBridge host → guest (\(text.utf8.count) bytes utf8)")
        vdagent.sendClipboardText(text)
    }

    // MARK: - guest → host

    private func applyGuestText(_ text: String) {
        guard enabled, let pb = pasteboard else { return }
        // declareTypes + setString — declareTypes 必调, 否则 setString 会被忽略
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        lastWrittenChangeCount = pb.changeCount
        // 同步 lastObservedChangeCount 防止下次 poll 把我们刚写的当成"host 端用户复制" 又回推
        lastObservedChangeCount = pb.changeCount
        log.info("PasteboardBridge guest → host (\(text.utf8.count) bytes utf8) changeCount=\(self.lastWrittenChangeCount)")
    }
}
