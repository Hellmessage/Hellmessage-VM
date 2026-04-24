// DisplayWindowController.swift
// 独立 VM 窗口. X 按钮点击触发 onRequestEmbed (嵌入主窗口), VM 不停机.
// 详见 docs/GUI.md "VM 显示窗口(独立 ⇄ 嵌入)"

import AppKit

public final class DisplayWindowController: NSWindowController, NSWindowDelegate {
    public let hvmView: HVMView

    /// X 按钮点击回调: 语义是 "嵌入主窗口", 不是 "关闭 VM"
    public var onRequestEmbed: (() -> Void)?

    /// 真正关闭窗口前的 cleanup (主动代码流, 不是 UI 按钮)
    public var onClose: (() -> Void)?

    public init(title: String, contentView: HVMView) {
        self.hvmView = contentView

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.titlebarAppearsTransparent = false
        w.tabbingMode = .disallowed
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = contentView
        w.center()
        w.collectionBehavior.insert(.fullScreenPrimary)

        super.init(window: w)
        w.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 语义重载: X 按钮 = 嵌入主窗口, VM 继续运行
        onRequestEmbed?()
        return false
    }

    /// 由主模型主动关闭独立窗口 (嵌入时或 VM 真停机时)
    public func closeWithoutEmbedCallback() {
        onRequestEmbed = nil
        onClose?()
        close()
    }
}
