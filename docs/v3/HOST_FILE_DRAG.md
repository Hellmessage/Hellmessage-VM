# Host → Guest 文件拖放 (NSDraggingDestination)

**状态**: 实现中 (2026-05-28)
**关联**: [HOST_FILE_PASTE.md](HOST_FILE_PASTE.md) (Cmd+V 通路, 复用其后端) / [FILE_COPY.md](FILE_COPY.md) (QGA 单文件 push)

---

## 1. 目标

用户在 Finder (或任何能拖出 file URL 的 source) 选中文件 → 拖入 HVM VM 的 framebuffer 区 → 释放 → 自动走 SPICE vdagent file_xfer 流到 guest, 落 `~/Downloads`. 通路跟 Cmd+V (HOST_FILE_PASTE.md) **同一条**, 只换触发方式.

## 2. 范围

- **接**: QEMU 后端 + Linux/Windows guest (跟 Cmd+V 同, FramebufferHostView 本来就只 QEMU 用)
- **接**: 主嵌入 view + detached 独立窗口
- **接**: 多文件批量拖, 文件夹自动 skip (同 Cmd+V 边界)
- **不接**: VZ 后端 / macOS guest (vdagent 不存在)
- **不接**: 拖出 (guest → host 文件) — v1 不做, 推 v2 自家 guest agent
- **不接**: 拖文本 / URL / 图片 (drag pasteboard 只看 `.fileURL`, 其他类型 reject)

## 3. 复用 vs 新增

| 层 | 复用 / 新增 |
|---|---|
| IPC op `clipboard.paste-files` | **复用**, 名字虽叫 paste-files 但语义是 "host 文件流给 guest", drag 走同一 op |
| `AppModel.pasteFilesToVM(item:urls:)` | **复用**, drop handler 调它 |
| `FilePasteBridge` + vdagent FILE_XFER | **复用**, server 端零改动 |
| `FramebufferHostView.onFilePaste` 闭包 | **复用**, drag drop 也调它 |
| `FramebufferHostView` 加 `NSDraggingDestination` 适配 | **新增** ~50 行 (registerForDraggedTypes + 4 个 NSDraggingDestination 方法) |
| Drag visual feedback (高亮边框 + 中央 hint) | **新增** ~30 行 (子 view + draggingEntered/Exited 切显隐) |

## 4. 实现要点

### 4.1 NSDraggingDestination 接入

`FramebufferHostView` 在 init 末尾:
```swift
registerForDraggedTypes([.fileURL])
```

实现 4 个方法 (NSDraggingDestination 协议):
- `draggingEntered(_:) -> NSDragOperation`
  - guard `inputCaptureEnabled && macStyleShortcuts && onFilePaste != nil`
  - 读 dragging pasteboard, 抽出 file URLs (跟 Cmd+V 同 `urlReadingFileURLsOnly`)
  - 空 / nil → 返 `[]` (拒)
  - 非空 → 显高亮 overlay + 文字 "拖放 N 个文件到 VM" + 返 `.copy`
- `draggingUpdated(_:) -> NSDragOperation` — 直接返 entered 时算的 operation (常驻 `.copy`)
- `draggingExited(_:)` — 隐高亮 overlay
- `performDragOperation(_:) -> Bool`
  - 读 file URLs, 隐 overlay
  - 调 `onFilePaste(urls)` (复用 Cmd+V 闭包)
  - 返 true

### 4.2 视觉反馈

`FramebufferHostView` 加私有子 view `dropOverlay`:
- 默认 `isHidden = true`
- 半透明黑底 + 居中 "拖放 N 个文件到 VM" SF Pro 文字
- 4 边贴齐 fbView, 但 alpha 0.4 半透明, 用户看得见底下 framebuffer 边缘
- 边框 2pt accent 色 (HVMColor.accent), 圆角 12pt

dragEnter 时拿 URL 个数填文字 + unhide. dragExit / perform 完 hide.

### 4.3 跟 captured 模式 / dialogActive 交互

- captured 模式 (Cmd+Opt) 期间也接收 drag (drag 是鼠标事件不是键盘, 不冲突)
- dialogActive 时 (例如 paste 错误弹窗), fbView 被 `isHidden=true` (我们最近加的 dialog visibility 修复), 拖到 fbView 区也命中不到 — 自然不接受 drop. 符合预期.
- detached 模式时主嵌入 view `inputCaptureEnabled=false` → 拒 drop (跟 Cmd+V 一致); detached 窗口的 fbView 接

### 4.4 跟 macStyleShortcuts 交互

`macStyleShortcuts=false` 时按 Cmd+V 文件粘贴关闭 (用户用 meta_l/Win 习惯). drag drop 同步遵守: false 时也拒 drop. 一条配置控两条触发路径.

## 5. 边界 / 容量限制

跟 Cmd+V 100% 一致 (后端同一条):
- 文件夹: skip + 通知 "暂不支持文件夹"
- 单文件 > 4 GiB: skip + 建议共享目录
- 多文件串行不并发
- 30s CAN_SEND_DATA / 600s 终态超时

## 6. PR 拆解

| PR | 范围 | 时间盒 |
|----|-----|-------|
| **PR-1** | FramebufferHostView 接 NSDraggingDestination + 4 方法 + dropOverlay 子 view + 视觉反馈 + 文档 + CLAUDE.md 加约束 | 1d |

单 PR 落地. 后端零改动, 完全复用 Cmd+V 通路.

## 7. 测试方案

1. 手动 e2e: Finder 拖文件 → HVM 主窗口 fbView → 释放 → 看 guest ~/Downloads (Windows VM `测试` 已验通)
2. 自动化: drag 用 NSEvent 注入比较复杂, v1 不写自动化测试; 后端走 `hvm-dbg paste-files` 已覆盖
3. 边界手测: 多文件 / 文件夹 / 大文件 / 拖到 sidebar (应不接) / detached 窗口拖入

## 8. 未决事项

| ID | 议题 | 默认 | 状态 |
|----|------|------|------|
| D1 | 拖入接受范围 | 仅 fbView, 不全窗口 | ✓ 已定 |
| D2 | drag 文本/URL 是否做 | v1 不接, 同 Cmd+V | ✓ 已定 |
| D3 | guest → host 反向拖出 | v1 不做 | ✓ 已定 |
| D4 | 视觉反馈风格 | 半透明黑底 + 中央文字 + accent 边框 | ✓ 已定 |
