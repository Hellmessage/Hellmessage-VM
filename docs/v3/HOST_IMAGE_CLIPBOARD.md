# Host → Guest 图片剪贴板 (CLIPBOARD mime=2 PNG)

**状态**: 实现中 (2026-05-28)
**关联**: [HOST_FILE_PASTE.md](HOST_FILE_PASTE.md) (Cmd+V 文件粘贴, 走 FILE_XFER 不同通路) / 待写 HOST_FILE_CLIPBOARD.md (UTM 风格文件粘贴, mime=6 FILE_LIST)

---

## 1. 目标 + 范围

### 1.1 用户故事
> "我在 macOS Cmd+Shift+4 截图 → 切到 VM 内 Telegram 输入框 → Ctrl+V → 图片粘贴进 Telegram 作为消息附件 (不是文件路径文本)"

### 1.2 做什么
- macOS 剪贴板内容是图片 (PNG / TIFF / JPG) → 自动同步到 guest 剪贴板, 以图片形式
- guest 内任何识别 image 剪贴板的 app (Telegram, Word, Paint, 浏览器富文本框 等) Ctrl+V 直接粘贴成 image data
- 跟现有文本剪贴板共存: macOS 剪贴板有文本 → guest 收文本; 有图片 → 收图片; 同时都有 → guest 自己挑

### 1.3 不做什么 (v1 范围外)
- **guest → host 图片** — guest 内截图 → Mac 粘贴图片. 推 v2 (要在 NSPasteboard 写 image, 跟现有 setString 路径平行加一条 setData)
- **CLIPBOARD_FILE_LIST (mime=6)** — UTM 风格 paste-where-you-paste 文件粘贴. 见独立提案 HOST_FILE_CLIPBOARD.md
- **PDF / RTF / HTML 等复杂 mime 类型** — 用户场景以 PNG 为绝大多数
- **GIF / 视频** — vdagent 协议 mime 不覆盖, guest app 不会指望

---

## 2. SPICE vdagent CLIPBOARD image mime

跟现有 text (mime=1) 同一条 GRAB → REQUEST → CLIPBOARD 流程, 只换 mime 字段:

```c
// spice-protocol/spice/vd_agent.h
enum {
    VD_AGENT_CLIPBOARD_NONE       = 0,
    VD_AGENT_CLIPBOARD_UTF8_TEXT  = 1,   // 现已实现
    VD_AGENT_CLIPBOARD_IMAGE_PNG  = 2,   // ← 本提案
    VD_AGENT_CLIPBOARD_IMAGE_BMP  = 3,
    VD_AGENT_CLIPBOARD_IMAGE_TIFF = 4,
    VD_AGENT_CLIPBOARD_IMAGE_JPG  = 5,
};
```

只实现 PNG (mime=2):
- macOS NSPasteboard 截图原生类型 = PNG (新版) 或 TIFF (老 app). TIFF 我们走 `NSBitmapImageRep → PNG` 转
- 全 OS guest vdagent 都吃 PNG (Linux spice-vdagent / Windows UTM Guest Tools 都行)
- 不必加 BMP/TIFF/JPG, 多写多 bug; 真有用户报需要再加

## 3. 关键技术点

### 3.1 多 chunk 发送 (critical bugfix)

现有 `VdagentClient.sendMessageLocked` 把整个 message 塞一个 chunk 发出去. text 剪贴板 < 1 KiB 没问题; PNG 截图通常 100 KiB ~ 几 MB, 单 chunk 直接撑爆 SPICE `VD_AGENT_MAX_DATA = 2048` 上限, guest vdagent decode 失败丢弃.

**修正**: 重写 sendMessageLocked 走 SPICE 标准的 message → chunks 切分:
- Chunk 1: chunk_header(8B) + message_header(20B) + payload[0..max-20)
- Chunk N: chunk_header(8B) + payload[next..max)
- 每 chunk body ≤ 2048

message_header 的 `size` 字段是 *总 payload 长度*; chunk_header 的 `size` 字段是 *本 chunk body 长度*. 接收端按 message_header.size 累加 chunks 直到拼完 (现有 runReadLoop 已处理 reassembly, 只是 send 路径单 chunk).

### 3.2 NSPasteboard 图片读取

```swift
private func readImagePNG(_ pb: NSPasteboard) -> Data? {
    // 1. 直接 PNG (现代 macOS 截图 / Chromium 等)
    if let png = pb.data(forType: .png) { return png }
    // 2. TIFF → PNG (老 app / 部分图像 app)
    if let tiff = pb.data(forType: .tiff),
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        return png
    }
    return nil
}
```

不读 JPG (NSPasteboard 罕见有 JPG 直接 type). 不读 PDF/HTML (image 范围外).

### 3.3 GRAB 多 mime 广告

现在 sendGrabLocked 只 advertise UTF8_TEXT. 改成根据 `pendingHostText` + `pendingHostImage` 动态 advertise 多 mime:

```swift
var mimes: [UInt32] = []
if pendingHostText  != nil { mimes.append(MIME_UTF8_TEXT) }
if pendingHostImage != nil { mimes.append(MIME_IMAGE_PNG) }
```

guest 收 GRAB 看到多 mime, 按自己上下文挑一个 REQUEST (Telegram 优先 image; Notepad 优先 text). vdagent 协议本来就这样设计.

### 3.4 REQUEST 分派

handleGuestRequestLocked 当前硬编码 UTF8_TEXT. 改成 switch on mime:
- `MIME_UTF8_TEXT` → send pendingHostText (现有)
- `MIME_IMAGE_PNG` → send pendingHostImage (新)
- else → log skip

### 3.5 PasteboardBridge 双值传递

把 `vdagent.sendClipboardText(_:)` 改成 `sendClipboardData(text:image:)`, 一次性把 text + image 都塞进 pending. GRAB 广告所有有内容的 mime.

PasteboardBridge.pollHostPasteboard:
```swift
let image: Data? = readImagePNG(pb)
let text: String? = pb.string(forType: .string)
if image == nil && (text == nil || text!.isEmpty) {
    vdagent.sendClipboardRelease()
} else {
    vdagent.sendClipboardData(text: text, image: image)
}
```

## 4. 实现 PR 拆解

| PR | 范围 | 时间盒 |
|----|-----|-------|
| **PR-1** | VdagentClient: MIME_IMAGE_PNG 常量, pendingHostImage slot, sendMessageLocked 多 chunk 重写, sendGrabLocked 多 mime, handleGuestRequestLocked 分派, sendClipboardData 公共 API. PasteboardBridge: readImagePNG, pollHostPasteboard 改 sendClipboardData. 加 hvm-dbg probe op `debug.set-image-clipboard` 给自动化测试用. 真机测 macOS 截图→Win VM Telegram. | 1d |

单 PR 落地. 跟 docs/v3/HOST_FILE_PASTE.md 不同通路, 后端 FilePasteBridge 不动.

## 5. 测试方案

### 5.1 协议层 (hvm-dbg)
- 创建 PNG 截图 → 写 NSPasteboard 通过 `screencapture -c -i` 或 `osascript`
- 等 PasteboardBridge 1Hz tick 同步
- guest 内 PowerShell 读 `[System.Windows.Forms.Clipboard]::GetImage()` 验证 image 存在 + 维度匹配

### 5.2 真机 e2e (用户场景)
- macOS Cmd+Shift+4 截图 → 切 VM (测试 Windows VM) → 打开 Telegram → Ctrl+V → 看图片粘贴成附件 (用户手测)

## 6. 已知边界

- **大图片性能**: 4K 截图 PNG ~5 MB, 2KB/chunk = 2500 chunks. virtio-serial 吞吐 ~50 MB/s, 100 ms 级延迟. 用户感知是 "复制完到 paste 之间有半秒延迟", 可接受
- **macOS pasteboard 类型**: 部分截图工具 (Snipaste 等第三方) 可能只放 RTF 含 image, 不放 PNG/TIFF — v1 不接, 用户走系统截图工具即可
- **changeCount race**: PasteboardBridge 已有 lastWrittenChangeCount 防 echo, image 路径继承该机制
- **协议 size 字段**: VDAgentMessage.size 是 u32 = 4 GiB max, 不限制 PNG 大小 (上限是 virtio-serial 吞吐 + guest 内存)

## 7. 未决事项

| ID | 议题 | 默认 | 状态 |
|----|------|------|------|
| D1 | guest → host image 反向 | v1 不做, 推 v2 | ✓ 已定 |
| D2 | 是否同时 advertise text + image | YES, 让 guest 自己挑 | ✓ 已定 |
| D3 | TIFF/JPG/BMP 是否支持 | 只 PNG, TIFF 入站转 PNG 出站 | ✓ 已定 |
| D4 | 图片大小上限 | 不硬限 (走 virtio-serial 自然限速) | ✓ 已定 |
