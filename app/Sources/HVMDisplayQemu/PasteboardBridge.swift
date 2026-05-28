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

    /// macOS Cmd+C 一个文件时触发. closure 由 QemuHostEntry 注入, 内部走
    /// HVMFileClipboardBridge.publishFiles — QGA 上传 + 通知 guest helper 设 Win clipboard
    /// (UTM 风格 paste-where-you-paste, docs/v3/HOST_FILE_CLIPBOARD.md).
    /// nil = 没接入文件剪贴板通路 (例如 Linux guest 或老 binary), file URLs 直接忽略.
    /// 在内部 Pasteboard 轮询线程上调; 调用方负责切到目标线程.
    public var onFileURLs: (([URL]) -> Void)?

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

        // 同时取 text + image PNG + file URLs. text/image 走 vdagent (mime 1/2),
        // file URLs 走 onFileURLs callback (独立的 HVMFileClipboardBridge 通路, 因为
        // UTM Guest Tools vdagent.exe 不实现 CLIPBOARD_FILE_LIST mime=6, 详见
        // docs/v3/HOST_FILE_CLIPBOARD.md).
        //
        // 优先级: file URLs 跟 text/image 都试 — Cmd+C 一个 file 时 NSPasteboard 通常
        // 同时含 file URL + 文件名文本, 我们各走各的 (guest 端 helper 设 CF_HDROP,
        // vdagent 设 text). Telegram 等 app 优先取 CF_HDROP (因为里面是文件).
        let text: String? = pb.string(forType: .string)
        let image: Data? = Self.readImagePNG(pb)
        let fileURLs: [URL]? = Self.readFileURLs(pb)
        let hasText = (text?.isEmpty == false)
        let hasImage = (image != nil)
        let hasFiles = (fileURLs?.isEmpty == false)

        if !hasText && !hasImage && !hasFiles {
            vdagent.sendClipboardRelease()
            return
        }

        // text / image → vdagent
        if hasText || hasImage {
            let textBytes = text?.utf8.count ?? 0
            let imageBytes = image?.count ?? 0
            log.info("PasteboardBridge host → guest (vdagent) text=\(textBytes) bytes image=\(imageBytes) bytes")
            vdagent.sendClipboardData(text: hasText ? text : nil,
                                       image: hasImage ? image : nil)
        }

        // file URLs → callback → HVMFileClipboardBridge (UTM 风格)
        if hasFiles, let urls = fileURLs, let cb = onFileURLs {
            log.info("PasteboardBridge host → guest (helper) files=\(urls.count)")
            cb(urls)
        }
    }

    /// 读 NSPasteboard 的 file URLs (仅 file URL, 排 https/RTF 等). 没有返 nil.
    private static func readFileURLs(_ pb: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return urls
        }
        return nil
    }

    /// 读 NSPasteboard 的 image 数据, 转 PNG. 支持类型: PNG (现代 macOS 截图, Chromium, Safari);
    /// TIFF (老 app, 部分图像 app) → 走 NSBitmapImageRep 转 PNG.
    /// 其他类型 (HEIC / RAW / 矢量) 返 nil 让 caller 当无图.
    private static func readImagePNG(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
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
