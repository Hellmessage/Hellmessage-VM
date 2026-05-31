// HVMDisplayQemu/PasteboardBridge.swift
//
// macOS NSPasteboard ↔ guest 剪贴板双向同步桥 (text / image / file URLs).
//
// 工作流:
//   - host → guest: 1Hz Timer 轮询 changeCount (NSPasteboard 无事件 API), 变化 → 读内容
//     → vdagent.sendClipboardData (text/image) + onFileURLs (file URLs 走 HVMFileClipboardBridge)
//   - guest → host: vdagent.onClipboardTextReceived → NSPasteboard 写 string, 记
//     lastWrittenChangeCount 比对避免 echo (host 写完 changeCount+1 不能反推回 guest)
//
// 启停由外部控制 (运行中可切换). 设计要点:
//   - 启动时 *不* 把当前 host 剪贴板推 guest (避免同步无关内容), 用户复制一次后才同步.

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

    /// macOS Cmd+C 文件时触发, 由 QemuHostEntry 注入 (内部走 HVMFileClipboardBridge.publishFiles).
    /// nil = 没接入文件剪贴板通路 (Linux guest), file URLs 忽略. 在轮询线程调.
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

        // text/image 走 vdagent (mime 1/2), file URLs 走 onFileURLs (独立
        // HVMFileClipboardBridge 通路, UTM vdagent.exe 不实现 CLIPBOARD_FILE_LIST mime=6).
        // Cmd+C 一个 file 时 NSPasteboard 通常同时含 file URL + 文件名文本, 各走各的.
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
