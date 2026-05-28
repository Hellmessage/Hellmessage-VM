# Host → Guest 文件粘贴 (Cmd+V 文件流)

**状态**: 代码已合入 (2026-05-28; 真机 P0 留给用户)
**关联**: [FILE_COPY.md](FILE_COPY.md) (单文件 push/pull) / [SHARED_FOLDER.md](SHARED_FOLDER.md) (持续共享) / [INPUT_CAPTURE.md](INPUT_CAPTURE.md) (键盘捕获边界)
**日期**: 2026-05-26 (稿) / 2026-05-28 (合入)

---

## 落地摘要 (2026-05-28)

PR-1~4 一次性合入. 关键改动点:

- **`HVMDisplayQemu/VdagentClient.swift`** — 加 `VD_AGENT_FILE_XFER_START/STATUS/DATA` 三消息编码 + `FileXferResult` 枚举 + `sendFileXferStart/Data/Status` API + `onFileXferStatus` 回调 + STATUS 入站解析
- **`HVMDisplayQemu/FilePasteBridge.swift`** — 新模块; per-id mailbox + Continuation 状态机, 串行处理 urls, 4 GiB 上限 / 文件夹 / 不存在 skip, CAN_SEND_DATA 30s / 终态 600s 超时
- **`HVMDisplayQemu/FramebufferHostView.swift`** — keyDown 拦 Cmd+V (排除 Opt/Shift/Ctrl 组合), 走 `readPasteboardFileURLs` 拿 file URL, 命中走 `onFilePaste` closure
- **`HVM/UI/Content/DetailContainerView.swift`** + **`HVM/UI/Detached/DetachedVMWindowController.swift`** — 给 FramebufferHostView 注入 `onFilePaste` closure → `AppModel.pasteFilesToVM`
- **`HVM/UI/App/AppModel.swift`** — `pasteFilesToVM` + `handlePasteFilesResponse` (Task.detached → IPC → 通知/错误弹窗)
- **`HVM/UI/App/HostFilePasteNotifier.swift`** — UNUserNotificationCenter wrapper, 首次自动 requestAuthorization
- **`HVMIPC/Protocol.swift`** — `clipboardPasteFiles = "clipboard.paste-files"` op + `IPCClipboardPasteFilesPayload`
- **`HVM/QemuHostEntry.swift`** — `QemuHostState.filePasteBridge` slot + `handleClipboardPasteFiles` handler (lazy install) + tearDown 清理
- **`hvm-dbg/Commands/PasteFilesCommand.swift`** — `hvm-dbg paste-files <vm> --file ...` 自动化测试入口

未决事项里 D11 (guest 没装 vdagent 的引导) 与 D12 (通知点击行为) 维持设计稿态: 当前
靠 30s 超时报 `等 CAN_SEND_DATA 超时` 通用 NSAlert 提示, 未做"自动引导安装弹窗" /
"通知点开 guest Downloads"; 推 v1.1.

---

## 1. 目标 + 范围

### 1.1 用户故事

> "我在 macOS Finder 选了几个文件按 Cmd+C, 切到 HVM VM 窗口里按 Cmd+V, 文件自动从宿主机传到虚拟机里, 完成后通知我。"

### 1.2 做什么

- macOS Finder (或任意 NSPasteboard 写入 file URLs 的源) Cmd+C 文件 → 切 VM 窗口 → Cmd+V
- HVM framebuffer view 拦 Cmd+V → 读 NSPasteboard 文件 URLs → 走 SPICE `VD_AGENT_FILE_XFER_*` 协议把文件流推给 guest
- guest 内 spice-vdagent (Linux) / UTM Guest Tools (Windows) 把文件落到 `~/Downloads` (或对应 OS 的 XDG_DOWNLOAD_DIR)
- 完成后 host 原生通知 "已传 N 个文件到 ~/Downloads"

### 1.3 不做什么 (硬边界, v1 范围外)

- **真正"粘贴到 guest 内当前焦点目录"** — 需要自家 guest agent (Win driver + Linux daemon) 拦 paste 事件 + 注入 CF_HDROP / uri-list, 工程量 1-2 月级别, 推 v2
- **文件夹** — SPICE file_xfer 协议本身只传单文件, 文件夹需要 tar 打包或递归. v1 拒文件夹, 弹通知 "暂不支持文件夹, 请先压缩"
- **guest → host 反向粘贴** (guest 内 Cmd+C 文件 → host Cmd+V) — 需 guest 端主动 push, 协议层支持但 spice-vdagent 默认走 GUI 拖拽不绑 Cmd+C. 推 v2
- **VZ 后端** — VZ 没有 virtio-serial vdagent 通路, 跟现有 PasteboardBridge 文本剪贴板限制一致, 仅 QEMU 后端
- **macOS guest** — VZ + 无 vdagent, 不在范围
- **进度 UI 中途取消** — v1 不可中断 (跟现有 FileTransferDialog 一致)
- **大文件硬上限以外的优化** — 单文件 4 GiB 软上限 (跟 SPICE 协议 + QGA 一致), 多文件总和无限制 (循环传)

### 1.4 决策结论 (用户已拍板)

- **D1**: 文件落 guest `~/Downloads` + host 原生通知 (不做"粘贴到当前目录")
- **D2**: Linux + Windows 同时做 (协议层一份代码)
- **D3**: 仅 framebuffer view 是 first responder 时拦 Cmd+V (跟键盘捕获边界一致)

---

## 2. UX 流程图

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Finder Cmd+C    │ →  │  NSPasteboard 写  │ →  │ (用户切到 HVM 窗口)│
│  3 个文件        │    │  public.file-url  │    │                  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
                                                          │
                                                          ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Cmd+V 按下      │ →  │ framebuffer view │ →  │ NSPasteboard 有  │
│  on VM 画面      │    │ keyDown 拦       │    │ file URLs ?      │
└──────────────────┘    └──────────────────┘    └──────────────────┘
                                                          │
                              ┌──────── YES ─────────────┘
                              ▼
                    ┌──────────────────┐
                    │  IPC 主进程 GUI  │
                    │  → host 子进程   │
                    │  clipboardPaste  │
                    │  FilesOp         │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ VdagentClient    │
                    │ sendFileXferStart│
                    │  (per file)      │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐    ┌──────────────────┐
                    │ guest spice-     │ →  │ 落 ~/Downloads/  │
                    │ vdagent 收 START │    │ <basename>       │
                    │ 回 CAN_SEND_DATA │    │                  │
                    └──────────────────┘    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │ host 流式 DATA   │
                    │ chunks ~2KB/msg  │
                    └──────────────────┘
                              │
                              ▼ (全部传完)
                    ┌──────────────────┐    ┌──────────────────┐
                    │ guest 回 STATUS  │ →  │ NSUserNotification│
                    │ SUCCESS          │    │ "已传 3 个文件到  │
                    │                  │    │  ~/Downloads"    │
                    └──────────────────┘    └──────────────────┘
```

NO 分支 (NSPasteboard 没 file URLs): 走老路径, framebuffer view.keyDown 把 cmd+v → ctrl+v keystroke 发给 guest (现有文本粘贴行为, 不变).

---

## 3. SPICE 协议: VD_AGENT_FILE_XFER_*

### 3.1 消息类型 + capability

```c
// 消息 type (跟 CLIPBOARD/MONITORS_CONFIG 同 type 字段)
#define VD_AGENT_FILE_XFER_START    12
#define VD_AGENT_FILE_XFER_STATUS   13
#define VD_AGENT_FILE_XFER_DATA     14

// capability bit (跟 CAP_CLIPBOARD_BY_DEMAND/CAP_CLIPBOARD_SELECTION 同 bitmap)
#define VD_AGENT_CAP_FILE_XFER_DISABLED  8   // guest 禁用 file xfer 时置位
// (没有专门 ENABLED bit, guest 不置 DISABLED 即视为启用)
```

### 3.2 消息体结构 (small-endian, packed)

**START** (host → guest):
```
+--------+--------+---------------------------+
| id u32 | size?  | GKeyFile 格式 string      |
+--------+--------+---------------------------+

GKeyFile body 示例 (\n 行分隔):
[vdagent-file-xfer]
name=document.pdf
size=1048576

# 字段:
#   name: 文件名 (basename, 不含路径)
#   size: 字节数
```

注: SPICE upstream `GKeyFile` 格式来自 GLib, 但实际只是简单的 INI-like 文本, 我们手写就行不需要引 glib.

**STATUS** (双向):
```
+--------+--------+
| id u32 | result |
+--------+--------+

result 枚举:
  0 = CAN_SEND_DATA        guest → host: START 收到 OK, 可以开始传 DATA
  1 = CANCELLED            guest → host: 用户取消 / 任意原因取消
  2 = ERROR                双向: 通用错误
  3 = SUCCESS              guest → host: 全部 DATA 收齐, 落地成功
  4 = NOT_ENOUGH_SPACE     guest → host: 目标分区空间不足
  5 = SESSION_LOCKED       guest → host: guest 内会话锁了 (lockscreen)
  6 = VDAGENT_NOT_CONNECTED guest → host: vdagent 内部状态错
  7 = DISABLED             guest → host: file_xfer 被禁
```

**DATA** (host → guest):
```
+--------+--------+----------+
| id u32 | sz u64 | payload  |
+--------+--------+----------+

# 单 chunk payload ≤ VD_AGENT_MAX_DATA - header (实测 ~2 KiB)
# sz 字段是 *本 chunk* 的 payload 字节数, 不是总 file size
```

### 3.3 SPICE chunking 限制

SPICE 协议 message 总长 ≤ 4096 字节 (VD_AGENT_MAX_DATA). file_xfer DATA chunk payload ~2 KiB. 1 MiB 文件需要 ~500 chunks, 1 GiB 需要 ~500K chunks. virtio-serial 吞吐 ~10-50 MiB/s, 大文件传输几分钟级.

---

## 4. 选型对比

### 4.1 备选方案

| 方案 | 通路 | 落地 | guest 端依赖 | 工程量 | 选/不选 |
|-----|------|-----|-------------|-------|---------|
| **A. SPICE file_xfer (本稿)** | vdagent virtio-serial | guest ~/Downloads | spice-vdagent (Linux) / UTM Guest Tools (Win), 现成 | 小 (~4 PR, 4d) | ✓ **选** |
| B. 自家 guest agent + CF_HDROP/uri-list | 自家 protocol + Win driver + Linux daemon | guest 当前 paste target 目录 | 自家 driver/daemon, **不存在** | 极大 (1-2月+ Win 签名) | ✗ v2 推后 |
| C. QGA `guest-file-write` | QGA virtio-serial (另一通路) | host 选择路径 | qemu-guest-agent (已有) | 中 (协议齐, 但 paste UX 需要再做) | ✗ 走重复路径 |
| D. SPICE WebDAV (临时挂载) | virtio-serial mux | guest 看 host 挂的目录 | spice-webdavd | 大 (需要 paste 时动态加 share) | ✗ 不合 Cmd+V 即时性 |
| E. virtiofs | virtio-fs PCI | guest 看 host 挂载 | guest virtiofsd | 大 (需要 QEMU patch + paste 流程改造) | ✗ 工程量大 |

### 4.2 为什么选 A

- **协议现成**: spice-vdagent (Linux) + UTM Guest Tools (Win ARM64) 都实现了 VD_AGENT_FILE_XFER_*. guest 端零开发
- **复用 vdagent socket**: HVM 已有 VdagentClient + single-client socket, 只加 3 个消息类型
- **复用 PasteboardBridge 思路**: 监 NSPasteboard 触发 → vdagent send, 跟现有文本剪贴板桥同款架构
- **跟 UTM / virt-manager / GNOME Boxes 一致** — 同款 UX, 用户跨虚机管理工具体验一致

### 4.3 为什么不选 B (真粘贴)

- Windows: 需要自家 driver 注册 IDataObject + IPasteSucceeded, 拦 Explorer 粘贴, 注入 CF_HDROP. driver 要签名 (跟 viogpudo 一样)
- Linux: 需要每个 desktop env 一份 daemon (GNOME / KDE / XFCE Nautilus / Dolphin 各家 paste hook 不同)
- guest paste target 目录拿到很难 (Win Shell IShellWindows / Linux Nautilus DBus), 拿不到时退化
- 工程量 1-2 月+, 远超用户当前期望

### 4.4 为什么不选 C (QGA)

QGA 没有 vdagent 的 "本机粘贴" UX 概念, QGA 是"执行命令 / 读写文件", 不会触发 guest 端通知. 用 QGA 的话 host 跟 guest 端没有反馈通路 (除非自己写 wrapper script). 而且 QGA push 是文件级 RPC, 不是流式协议, 大文件性能差 (1-10 MiB/s, 跟 FILE_COPY.md 实测一致).

---

## 5. 实现要点

### 5.1 VdagentClient 扩展

`app/Sources/HVMDisplayQemu/VdagentClient.swift`:

```swift
// 新加常量
private static let VD_AGENT_FILE_XFER_START: UInt32  = 12
private static let VD_AGENT_FILE_XFER_STATUS: UInt32 = 13
private static let VD_AGENT_FILE_XFER_DATA: UInt32   = 14
private static let VD_AGENT_CAP_FILE_XFER_DISABLED: UInt32 = 8

// transfer id 分配器 (atomic 递增)
private var nextTransferId: UInt32 = 1
private let transferIdLock = NSLock()

// 进行中的传输状态机 (按 id 索引)
public struct FileXferState {
    public let id: UInt32
    public let name: String
    public let totalSize: UInt64
    public var sentBytes: UInt64
    public var awaitingCanSend: Bool
    public var finished: Bool
    public var error: HVMError?
}
private var transfers: [UInt32: FileXferState] = [:]
private let transfersLock = NSLock()

// public API
/// 发起一次文件传输. 返回 transfer id; 回调通过 onFileXferStatus 异步触发.
/// 实际 DATA 推送由 sendFileXferStartLocked 调用方 (FilePasteBridge) 拿 CAN_SEND_DATA
/// 后驱动 sendFileXferData 串行送 chunk.
public func sendFileXferStart(name: String, size: UInt64) -> UInt32

/// 送一个 chunk. payload ≤ kVdagentFileXferChunkSize (~2 KiB).
/// 返回 false 表示 socket 写失败.
public func sendFileXferData(id: UInt32, chunk: Data) -> Bool

/// guest STATUS 回调 (内部 readLoop 收到 STATUS 时调). result 用 enum 投映.
public var onFileXferStatus: ((UInt32, FileXferResult) -> Void)?

public enum FileXferResult: UInt32, Sendable {
    case canSendData = 0
    case cancelled = 1
    case error = 2
    case success = 3
    case notEnoughSpace = 4
    case sessionLocked = 5
    case vdagentNotConnected = 6
    case disabled = 7
}
```

**chunk 大小常量**: `kVdagentFileXferChunkSize = 2048` (SPICE 上游 hard cap ~2 KiB, 含 message header). 实测 spice-vdagent 接受 ≤ 4 KiB, 我们走 2 KiB 保守.

### 5.2 FilePasteBridge (新模块)

`app/Sources/HVMQemu/FilePasteBridge.swift`:

```swift
// 跟 PasteboardBridge 平行, 不复用 (PasteboardBridge 是文本路径, 1Hz 轮询).
// 文件路径不轮询 — 只在 framebuffer view 通知 "用户按了 Cmd+V" 时主动读 NSPasteboard.
//
// 流程:
//   1. framebuffer view keyDown 拦 Cmd+V (macStyleShortcuts=true)
//      → 读 NSPasteboard public.file-url types
//      → 有 → 调 FilePasteBridge.handlePasteFiles(urls)
//      → 无 → 走老路径 (cmd+v → ctrl+v 给 guest)
//   2. FilePasteBridge 串行处理 urls:
//      - 文件夹: 跳过 + 标记 errors
//      - 大于 4 GiB: 跳过 + 标记 errors
//      - 普通文件: vdagent.sendFileXferStart(name, size) → 等 CAN_SEND_DATA
//        → 流式读 file → sendFileXferData chunks → 等 SUCCESS / 错误
//   3. 完成 → onAllDone 回调 GUI 主进程 → NSUserNotification
//
// 单 active transfer 串行, 不并发 (vdagent socket 单 client + SPICE 协议 chunks
// 共用 stream, 并发会 interleave 不可恢复). 多文件依次传.

@MainActor
public final class FilePasteBridge {
    private let vdagent: VdagentClient

    public init(vdagent: VdagentClient) { self.vdagent = vdagent }

    public func handlePasteFiles(_ urls: [URL]) async -> PasteResult

    public struct PasteResult {
        public let successful: [URL]
        public let skipped: [SkippedFile]      // 文件夹 / 超大文件 / 读不了
        public let failed: [FailedFile]        // vdagent 报错
    }
}
```

### 5.3 framebuffer view 拦截

`app/Sources/HVMDisplayQemu/FramebufferHostView.swift` keyDown 改:

```swift
public override func keyDown(with event: NSEvent) {
    guard inputCaptureEnabled else { return }
    syncCapsLockIfNeeded(modifierFlags: event.modifierFlags)
    if event.isARepeat { return }

    // 拦 Cmd+V 文件粘贴: 仅 macStyleShortcuts=true (cmd 当 ctrl 用) + framebuffer
    // first responder. macStyleShortcuts=false 时用户在用 meta_l/Win 键, 不绕路.
    if macStyleShortcuts,
       event.modifierFlags.contains(.command),
       !event.modifierFlags.contains(.option),    // Cmd+Opt 是 capture toggle, 排除
       event.charactersIgnoringModifiers == "v" {
        if let urls = readPasteboardFileURLs(),  !urls.isEmpty {
            // 通过 closure 注入 (上层 binder 把 GUI 主进程 IPC 调用塞进来)
            onFilePaste?(urls)
            return  // *不* 走 keystroke 路径
        }
    }

    // 老路径 (文本粘贴 / 其他键)
    if let qcode = HVMQCode.qcode(forKeyCode: event.keyCode) {
        forwarder?.keyDown(qcode: qcode)
        pressedNormalKeyQcodes.insert(qcode)
    }
}

/// 由 GUI 层注入 — 主进程 binder 拿 vmId 后通过 IPC 调 host 子进程 clipboardPasteFiles
public var onFilePaste: (([URL]) -> Void)?

private func readPasteboardFileURLs() -> [URL]? {
    let pb = NSPasteboard.general
    // public.file-url 优先 (现代 macOS); NSFilenamesPboardType 兜底 (老 app)
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
       !urls.isEmpty {
        return urls.filter { $0.isFileURL }
    }
    return nil
}
```

### 5.4 IPC 新 op: clipboardPasteFiles

`app/Sources/HVMIPC/Protocol.swift`:

```swift
public extension IPCOp {
    static let clipboardPasteFiles = IPCOp(rawValue: "clipboard.paste-files")
}

public struct IPCPasteFilesReq: Codable, Sendable {
    public let urls: [String]   // host 绝对路径, host 子进程读
}

public struct IPCPasteFilesResp: Codable, Sendable {
    public let successful: [String]
    public let skipped: [SkipReason]
    public let failed: [FailReason]
}
```

GUI 主进程拿 `urls` → IPC `clipboardPasteFiles` 给 host 子进程 → host 子进程读文件 + 走 vdagent 推 guest. host 子进程跑流式传输, 主进程异步等响应 (长事务, 用 600s timeout, 跟 FileTransferDialog 一致).

### 5.5 GUI 通知

- **成功**: 走 macOS `UNUserNotificationCenter` 发原生通知 "已传 N 个文件到 VM 飞机 ~/Downloads"
  - 点通知不做事 (落地路径在 guest 内, host 无法跳转)
- **错误**: NSAlert (走统一 ErrorDialog 路径) "粘贴失败: <文件名> <原因>"
- **进度**: v1 **不做** 实时进度条 (跟 PasteboardBridge 文本同款无 UI). v1.1 可加顶部 banner

### 5.6 host 子进程 vdagent 单一性

vdagent socket 是 single-client. FilePasteBridge 跟 PasteboardBridge 共用 **同一个 VdagentClient 实例** (`QemuHostState.shared.vdagent`). 协议层 VdagentClient 把 send 写入串行化 (现有 `writeQueue`), 文本剪贴板 + 文件传输在同 socket 上 message-by-message 不冲突.

新加 `pasteboardBridge` 类比, 在 `QemuHostState`:

```swift
public actor QemuHostState {
    var pasteboardBridge: PasteboardBridge?
    var filePasteBridge: FilePasteBridge?     // 新加
}
```

启动期 `QemuHostEntry.run` 跟 PasteboardBridge 一并起 (config.clipboardSharingEnabled 控制).

---

## 6. guest 端依赖

| guest OS | 依赖 | 安装方式 | 默认配置 |
|---------|-----|---------|---------|
| Linux (Ubuntu / Debian / Fedora) | `spice-vdagent` | `sudo apt install spice-vdagent` (Debian/Ubuntu) | systemd 自启, 落 ~/Downloads |
| Windows arm64 | UTM Guest Tools (含 spice-guest-tools 的 ARM64 端口) | 用户首次跑 Windows VM 时 GUI 引导下载 | 服务自启, 落桌面 (UTM Guest Tools 设定) |

**guest 没装时**: vdagent 协议层 caps 协商时 guest 不回 caps (或 socket 没 server 端), host VdagentClient.sendFileXferStart 写失败 (socket 没监听 end) → onFileXferStatus 永不触发 → 30s 超时, 落 NSAlert "guest 未安装 spice-vdagent". 设计稿 v1.1 可加 guest 检测 + 引导安装弹窗.

CLAUDE.md 共享目录约束有明确"**guest 端依赖外置, 不自家 build phodav**"原则, file_xfer 沿用.

---

## 7. 边界 / 容量限制

| 项 | v1 限制 | 原因 |
|----|--------|-----|
| 单文件大小 | 4 GiB 软上限 | 跟 SPICE 协议 + QGA 一致, > 4 GiB 弹通知建议走共享目录 |
| 多文件总和 | 无硬限 | 串行传, 慢但不死 |
| 文件夹 | 拒 + 通知 | 协议层只传单文件 |
| 并发 | 不并发 | vdagent socket 单 client, SPICE chunk 不可 interleave |
| 取消中途 | v1 不支持 | UI 没做取消按钮 |
| guest 文件名冲突 | guest 端 (spice-vdagent) 自动加 `(1)` 后缀 | 不是我们的事, guest 行为已知 |
| 路径校验 | host 端不限制 (用户已经 Finder Cmd+C 选定 = 显式授权) | 跟 NSOpenPanel 走的 push 一致 |

---

## 8. 跟现有路径的交互

### 8.1 跟 PasteboardBridge (文本剪贴板) 交互

- 不冲突: vdagent 单 socket 多消息类型, VdagentClient 内部 writeQueue 串行化
- 用户 Finder 复制文件 (NSPasteboard 是 file URLs, **不是** 文本) → PasteboardBridge 文本轮询忽略 (它只读 .string)
- 用户在 macOS 文本框 Cmd+C 文字 → PasteboardBridge 1Hz 轮询发文本 → guest 文本剪贴板更新. 这俩路径并存

### 8.2 跟 macStyleShortcuts 交互

- macStyleShortcuts=true: Cmd+V 被映射成 ctrl+v 给 guest. 我们在 keyDown 拦截层 (映射之前) 提前判断 file URLs, 有就走 file xfer 不发 keystroke
- macStyleShortcuts=false: Cmd → meta_l (Win), 用户不在用 mac-style 习惯, **不拦** Cmd+V (走老路径 meta_l+v)
  - 用户若仍想粘文件 → 走 v1.1 加的 "工具栏粘贴按钮" 兜底 (推后)

### 8.3 跟键盘捕获 (captured 模式) 交互

- captured 模式开/关 都拦. captured 不改 Cmd+V 行为
- Cmd+Opt 是 capture toggle, **必须排除**: keyDown 拦截判定加 `!event.modifierFlags.contains(.option)`. 否则用户按 Cmd+Opt+V 想干啥时被误判

### 8.4 跟 FileTransferDialog (单文件 push) 交互

- 不冲突: FileTransferDialog 走 QGA `guest-file-write`, 跟 vdagent file_xfer 完全两套通路
- 后续可能把 FileTransferDialog 也改走 vdagent file_xfer (统一通路 + 性能更好), 但 v1 不改

### 8.5 跟 SPICE WebDAV 共享目录交互

- 不冲突: WebDAV 也走 vdagent socket 但用 mux 子协议 (org.spice-space.webdav.0), 跟 vdagent 主协议层不同 chardev
- 实际上当前实现里 WebDAV 跟 vdagent 走同一 chardev 还是分开? 看 QemuHostEntry — **核对**: `vdagentSocketURL` 跟 webdav 是分开的 chardev (一个 `com.redhat.spice.0`, 一个 `org.spice-space.webdav.0`). 两条 virtserialport, 不抢

---

## 9. 风险 + 待验证

### P0 (上线前必过)

- **P0-1**: spice-vdagent 真机收到 FILE_XFER_START → 回 CAN_SEND_DATA → 收完 DATA → 回 SUCCESS 全闭环 (Linux + Windows 各跑一遍)
- **P0-2**: 4 GiB 文件传输不 OOM (Swift 端流式读 + 串行 chunk, 不一次读全)
- **P0-3**: Cmd+V 拦截不影响纯文本粘贴 (NSPasteboard 没 file URLs → 走老路径正常)
- **P0-4**: guest 没装 spice-vdagent 时 30s 超时 + NSAlert 提示, **不**永久 hang
- **P0-5**: 取消中途 (用户按 Cmd+Q / 停 VM): vdagent client 优雅释放, 不留 orphan transfer state

### P1 (上线后跟踪)

- **P1-1**: 多文件 (~10) 总和 1 GiB 串行传输总时间 (UX 期望 < 1 min on 50 MiB/s virtio-serial)
- **P1-2**: guest 内 file_xfer 落点是否真在 ~/Downloads (Linux XDG_DOWNLOAD_DIR / Windows UTM Guest Tools 设定路径)
- **P1-3**: Cmd+V 拦截跟 captured 模式 / detached 窗口的交互边界

### 已知妥协

- 不能"粘贴到当前焦点目录" (推 v2 自家 guest agent)
- 不能传文件夹 (推 v2 tar pack 或目录递归)
- 不能取消中途 (推 v2 加 UI)
- guest → host 反向不做 (推 v2)

---

## 10. PR 拆解

| PR | 范围 | 时间盒 | 验收 |
|----|-----|-------|-----|
| **PR-1** | VdagentClient 加 `VD_AGENT_FILE_XFER_START/STATUS/DATA` 三消息编码 + decode 路径 + onFileXferStatus 回调 + chunk 串行 send API. 加 `hvm-dbg vdagent-fxfer` 子命令做协议级回环测试 (host 跟自家 mock guest server 跑一遍) | 1d | 1) build 通 2) hvm-dbg vdagent-fxfer 发 4 MiB 测试文件能完整收到 + SUCCESS |
| **PR-2** | FilePasteBridge 新模块. FramebufferHostView.keyDown 拦 Cmd+V + 读 NSPasteboard file URLs + onFilePaste closure. IPC clipboardPasteFiles op + host 子进程 handler (调 FilePasteBridge). DetailContainerView / DetachedVMWindowController 注入 closure → IPC | 2d | 1) 真机 Linux guest 收文件到 ~/Downloads 2) 文本剪贴板不受影响 |
| **PR-3** | GUI 反馈: 成功 UNUserNotification, 错误 ErrorDialog, "跳过文件夹/超大文件" 通知文案. 文件夹检测 + 4 GiB 上限检测. | 1d | 1) 真机粘贴 3 文件 → 桌面通知 2) 选文件夹粘贴 → 通知 "不支持" |
| **PR-4** | `hvm-dbg paste-files <vm> <file...>` 自动化测试子命令 + Windows guest 真机验证 (UTM Guest Tools) + 设计稿状态改 "代码已合入" + 回写 docs/v1/ + CLAUDE.md 加约束 | 1d | 1) hvm-dbg paste-files 跑通 2) Windows arm64 收文件到桌面 |

**总计**: 5 天 (含 Windows arm64 真机 e2e, 单 PR 颗粒 ≤ 2 天符合 CLAUDE.md 颗粒度约束)

---

## 11. 未决事项 (Decisions)

| ID | 议题 | 当前默认 | 决策时机 | 状态 |
|----|------|---------|---------|------|
| D1 | 落地行为 | 落 guest ~/Downloads + 原生通知 | 设计稿阶段 | ✓ 已定 |
| D2 | guest OS 范围 v1 | Linux + Windows 同时 | 设计稿阶段 | ✓ 已定 |
| D3 | Cmd+V 拦截触发条件 | framebuffer view first responder | 设计稿阶段 | ✓ 已定 |
| D4 | 多文件并发 | v1 串行, 不并发 | 设计稿阶段 | ✓ 已定 |
| D5 | 文件夹支持 | v1 拒 + 通知, 推 v2 | 设计稿阶段 | ✓ 已定 |
| D6 | 单文件容量上限 | 4 GiB 软上限, 跟 QGA / SPICE 一致 | 设计稿阶段 | ✓ 已定 |
| D7 | 进度 UI | v1 仅完成通知, 不做实时进度. v1.1 加顶部 banner | 设计稿阶段 | ✓ 已定 |
| D8 | macStyleShortcuts=false 时是否也拦 Cmd+V | v1 不拦 (用户不在用 mac-style 习惯). v1.1 可加工具栏按钮 | 设计稿阶段 | ✓ 已定 |
| D9 | VZ 后端是否接 | v1 不接 (VZ 无 vdagent). 推后看 VZSharedDirectory 提案 | 设计稿阶段 | ✓ 已定 |
| D10 | guest → host 反向粘贴 | v1 不做, 推 v2 | 设计稿阶段 | ✓ 已定 |
| D11 | guest 没装 vdagent 的引导 | v1 超时 + 通用 NSAlert. v1.1 加引导安装弹窗 | 实现期决定 | ⏳ 待 PR-3 |
| D12 | 通知点击行为 | v1 不做 (host 跳不了 guest 路径). v1.1 可触发 hvm-dbg shell 打开 guest Downloads | 实现期决定 | ⏳ 待 PR-3 |

---

## 12. 回写计划 (实现合入后)

- `docs/v1/CLIPBOARD.md` (如不存在则新建) 加 "文件粘贴" 节, 描述当前现状
- `CLAUDE.md` 加约束:
  - "Cmd+V 文件粘贴" 边界 (guest ~/Downloads, 不是当前目录)
  - "vdagent 单 socket 多协议复用" 原则 (PasteboardBridge / FilePasteBridge / WebDAV 共存)
  - "host → guest 文件传输统一通路" 是 SPICE vdagent file_xfer (不再走 QGA, FileTransferDialog 后续也迁)
- 设计稿头部状态改 `代码已合入`, 留底不删

---

## 13. 参考实现

- SPICE 协议: <https://www.spice-space.org/spice-protocol.html> §4.4 (vdagent)
- spice-vdagent 上游: <https://gitlab.freedesktop.org/spice/linux/vd_agent_protocol> `vd_agent_protocol.h`
- UTM Guest Tools (Windows ARM64): <https://getutm.app/downloads/utm-guest-tools-latest.iso> 含 spice-vdagent ARM64 端口
- HVM 本地: `app/Sources/HVMDisplayQemu/VdagentClient.swift` (现有 CLIPBOARD 通路, 加 FILE_XFER 拓展)
- HVM 本地: `app/Sources/HVMQemu/PasteboardBridge.swift` (文本剪贴板桥, 架构参考)
- HVM 本地: `docs/v3/FILE_COPY.md` (QGA 单文件传, 路径选型对比)
