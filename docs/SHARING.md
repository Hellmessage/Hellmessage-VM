# SHARING — host ↔ guest 数据共享

本文档描述 HVM 当前 (QEMU-only, guest 仅 Linux / Windows arm64) 在宿主机 ↔ guest 之间
交换数据的全部通路: **共享目录** / **文本+图片剪贴板** / **Cmd+V 文件粘贴** / **文件传输**。

所有通路都建立在 QEMU 的 `virtio-serial` chardev (`server=on` unix socket) 之上, HVM 主进程 /
VMHost 子进程作 client 连入。HVM **不链 libspice-server / libphodav, 不给 QEMU 加 `--enable-spice`**,
所有协议 (SPICE WebDAV / spice-vdagent / QGA JSON) 都在 Swift 进程内自实现 single-client。

> 范围边界: 仅 QEMU 后端 + Linux / Windows guest。macOS guest / VZ 后端已整体移除, 不在本文范围。

---

## 1. 四条通路总览

| 通路 | 后端协议 | host 实现 | guest 端依赖 | socket (per-VM) | virtio-port | 速度 / 上限 |
|------|----------|-----------|--------------|------------------|-------------|-------------|
| **共享目录** | SPICE WebDAV over virtio-serial mux | `SpiceWebdavServer` (`HVMQemu`) | spice-webdavd (Win/Linux) | `<uuid>.webdav.sock` | `org.spice-space.webdav.0` | 长期挂载, 持续读写 |
| **文本 / 图片剪贴板** | spice-vdagent (CLIPBOARD) | `PasteboardBridge` → `VdagentClient` (`HVMDisplayQemu`) | spice-vdagent | `<uuid>.vdagent.sock` | `com.redhat.spice.0` | 即时, UTF-8 文本 + PNG |
| **Cmd+V 文件粘贴** | spice-vdagent (FILE_XFER) | `FilePasteBridge` → `VdagentClient` | spice-vdagent | `<uuid>.vdagent.sock` (同上) | `com.redhat.spice.0` | ~50 MB/s 量级, 落 guest `~/Downloads`, ≤ 4 GiB |
| **文件传输 (push/pull)** | qemu-guest-agent (`guest-file-*`) | `QgaFile` (`HVMQemu`) | qemu-ga | `<uuid>.qga.sock` | `org.qemu.guest_agent.0` | 实测 8-12 MB/s, 软警告 100 MiB / 硬上限 4 GiB |

> 另有一条 **Windows 专用文件剪贴板** (UTM 风格 paste-where-you-paste): `HVMFileClipboardBridge`
> + 自家 `hvm-guest-helper.exe`, 走 QGA 上传 + JSON 帧设 Win clipboard, virtio-port
> `com.hellmessage.hvm-clipboard.0`。详见 §4.3。

socket 路径全部由 `HVMPaths` 集中派生 (`app/Sources/HVMCore/Paths.swift`), **禁止业务侧自己拼路径**:

- `HVMPaths.webdavSocketPath(for:)` → `~/Library/Application Support/HVM/run/<uuid>.webdav.sock`
- `HVMPaths.vdagentSocketPath(for:)` → `…/run/<uuid>.vdagent.sock`
- `HVMPaths.qgaSocketPath(for:)` → `…/run/<uuid>.qga.sock`
- `HVMPaths.hvmClipboardSocketPath(for:)` → `…/run/<uuid>.hvm-clipboard.sock`

---

## 2. 共享目录 (SPICE WebDAV)

实现: `app/Sources/HVMQemu/SpiceWebdavServer.swift`。设计稿 `docs/v3/SHARED_FOLDER.md`,
现状 `docs/v1/SHARING.md`。

### 2.1 架构

```
QEMU chardev (server=on) ── unix socket ── SpiceWebdavServer (HVM 作 client connect)
                                                │
                                                ├─ readThread: 读 mux frame, 按 client_id demux
                                                │      → 各自 HTTPRequestParser → 完整请求
                                                │
                                                ├─ writeQueue (serial): 跑 WebDavHandler.process
                                                │      → HTTPResponse → 切 mux frame → 写 socket
                                                │
                                                └─ roots: [Root] (host 路径 + readOnly, 唯一来源)
```

guest 内 `spice-webdavd` 服务把本地 `\\localhost\dav` (Win) / GVFS `davs://` (Linux) 的
HTTP 流, 通过 virtio-port `org.spice-space.webdav.0` 转给 host。

### 2.2 Mux wire 协议 (跟 phodav 对齐)

```
frame: [client_id u64_le][size u16_le][payload <= 65535 bytes]
```

- `size == 0` = client 主动关连接信号。
- HTTP 跨多 frame 时同 `client_id` 关联, payload 按字节拼接还原 HTTP 流。
- 大响应分多 frame, 每片 ≤ 65535 (`MuxFrame.encode()` 里 `precondition(payload.count <= 65535)`)。

帧编解码: `MuxFrame.tryParse` / `MuxFrame.encode` (10 字节 header = 8B client_id + 2B size)。

### 2.3 内置 WebDAV server (不链 libphodav)

`WebDavHandler` 自实现 HTTP/1.1 + WebDAV 动词, 支持:
`OPTIONS / PROPFIND / GET / HEAD / PUT / DELETE / MKCOL / MOVE / COPY / PROPPATCH / LOCK / UNLOCK`。

几个为兼容 Windows shell 的关键处理 (基于真实代码):

- **`PROPFIND` 必返 quota** (`quota-available-bytes` / `quota-used-bytes`, RFC 4331): Win WebDAV
  mini-redirector 没 quota 会按 free=0 拒所有 PUT (报误导性的 "File Too Large for destination")。
  走 host 卷 `volumeAvailableCapacityForImportantUsage`, 拿不到兜底 1 TiB。
- **`PROPPATCH` 返 207 Multi-Status** 而非裸 200: Win shell `IFileOperation` 看到裸 200 会判
  "事务没真 commit", PUT 完文件后还发 DELETE 回滚。
- **`LOCK` 返假锁** (`opaquelocktoken:<uuid>` + `Lock-Token` header), **不维护真实锁状态**:
  Win `IFileOperation` 必须能 LOCK 成功才不回滚事务。单用户单机无并发竞争, 假锁够用。
- **`PROPFIND Depth: infinity` 拒** (返 403): 防递归列大目录卡死 server。
- HTTP 解析不支持 `chunked` transfer (phodav-mount 不用), body 长度由 `Content-Length` 决定;
  header 超 256 KB / 单 request buffer 超限判 protocol error 关 client。

### 2.4 路径安全 (硬约束)

所有 guest 路径必须落在 `roots[].url` 子树内。两个入口函数:

- **`toHostURL(_:)`** (用于 PROPFIND / GET / DELETE / MOVE 源等已存在路径):
  1. root 名必须在 `rootsByName` 内, 否则返 nil;
  2. 逐段拒 `..` / `.` / 空段;
  3. `resolvingSymlinksInPath()` 后比对 `standardizedFileURL.path`, 仍须 `== rootPath` 或
     `hasPrefix(rootPath + "/")` (拼 `/` 防 `/foo/baz` 命中 `/foo/bar` 前缀错觉)。symlink follow
     后越界一律拒。

- **`composeDest(root:sub:)`** (用于 PUT / MKCOL / MOVE-COPY 目标, 目标可能尚不存在所以不能
  realpath 整路径): 同样逐段拒 `..` / `.` / 空段, 然后对**父目录** `resolvingSymlinksInPath()`
  后校验仍在 root 子树内。

只读保护: `Root.readOnly == true` 时 `PUT / DELETE / MKCOL / MOVE / COPY` 一律 403。

### 2.5 配置 / 字段约束

`SharedFolderSpec` (`app/Sources/HVMBundle/VMConfig.swift`):

- **name 字符集**: `SharedFolderSpec.sanitizeName` 限 `[a-zA-Z0-9_-]{1,32}` — 非允许字符替换成
  `_`, 截断到 32, 空 → `"share"`。防 WebDAV URL 注入 / shell metachar。
- **hostPath 必须绝对路径 + 真实存在**: CLI / GUI 入口校验, 防相对路径歧义。
- `readOnly` 默认 true (老 yaml 缺字段 → decode 兜底 true, 保守安全)。

### 2.6 生命周期 gating

- **空 `sharedFolders` 不起 server**: `QemuHostEntry` 仅在 `!config.sharedFolders.isEmpty` 时
  注入 chardev argv + 起 `SpiceWebdavServer`, 否则不占 socket 路径、不注入 chardev。
- **VM running 改 `sharedFolders` 拒**: chardev 不支持热挂, 落 `bundle.busy` 让用户先停 VM。
  CLI / GUI 都遵守。
- **server 启失败 fail-soft**: 起不来只 log warn, **不阻塞 VM 启动** (共享目录非 VM 必需)。
- **改 `sharedFolders` 必走加密分流**: 走 `store.saveConfig` / `EncryptedConfigEditor.save`
  (内部分流 BundleIO.save / EncryptedConfigIO.save), 禁止直接 BundleIO.save。

### 2.7 guest 端依赖 (外置, 不自家 build)

- **Windows**: UTM Guest Tools 自带 `spice-webdavd-arm64-latest.msi`。
- **Linux**: 用户 `sudo apt install spice-webdavd`。
- **不**自家 build phodav 替代上游。

---

## 3. 文本 / 图片剪贴板 (spice-vdagent)

实现: `app/Sources/HVMDisplayQemu/PasteboardBridge.swift` + `VdagentClient.swift`。

### 3.1 双向同步

NSPasteboard 无事件 API, 只能轮询 — 跟 UTM (`UTMPasteboard` 1Hz Timer) 一致。

- **host → guest**: 1Hz `Timer` 轮询 `NSPasteboard.general.changeCount`, 检测到变化 → 读
  text / image PNG / file URLs → `vdagent.sendClipboardData(text:image:)` (走 GRAB → 等 guest
  REQUEST → 发 CLIPBOARD 数据)。
- **guest → host**: `VdagentClient.onClipboardTextReceived` 回调 → 写 NSPasteboard, 记录
  `lastWrittenChangeCount` 防 echo (host 写完 changeCount +1, 下次轮询不能再当成"用户复制"回推)。

支持的内容:

- **文本**: UTF-8 (mime `MIME_UTF8_TEXT = 1`)。
- **图片**: PNG (现代截图 / Chromium / Safari) 直接走; TIFF (老 app) 经 `NSBitmapImageRep`
  转 PNG (mime `MIME_IMAGE_PNG = 2`)。HEIC / RAW / 矢量返 nil 当无图。
- **file URLs**: 不走 vdagent CLIPBOARD, 改走独立 `onFileURLs` callback → `HVMFileClipboardBridge`
  (见 §4.3); 因为 UTM Guest Tools 的 `vdagent.exe` 不实现 `CLIPBOARD_FILE_LIST` (mime=6)。

启动行为: `start()` **不**把当前 host 剪贴板推 guest (避免启动时 host 上恰好有的无关内容被同步),
用户复制一次后才同步。

### 3.2 per-VM 可热改

- config `clipboardSharingEnabled`: 启动时按配置决定是否 `PasteboardBridge.start()`。
- 运行中可热改 (`requireStopped=false`): GUI `store.setClipboardSharing` / `setEnabled(_:)` →
  `start()` / `stop()`。`stop()` 摘回调 + 通知 guest `CLIPBOARD_RELEASE`。

### 3.3 vdagent caps 协商 (要点)

- host 永远 advertise `CLIPBOARD_BY_DEMAND (5)` + `CLIPBOARD_SELECTION (6)`; 是否真带
  selection prefix (1B selection + 3B pad) 看 guest 是否也 advertise SELECTION (UTM Win 版
  vdagent caps 缺 bit 6, 它自己不带 prefix, 严格按协商即可)。
- 不协商基础 `CLIPBOARD (3)` — 那是无 GRAB/REQUEST 的 push, 跟 pull 模式冲突。
- message type 编号严格按 `spice-protocol/spice/vd_agent.h`: `START=10 / STATUS=11 / DATA=12`,
  `CAP_FILE_XFER_DISABLED=13` (历史曾错位 2, guest 静默丢未知 type 导致 30s timeout)。

---

## 4. Cmd+V 文件粘贴 (spice-vdagent FILE_XFER)

实现: `app/Sources/HVMDisplayQemu/FilePasteBridge.swift` + `VdagentClient.swift` 的 FILE_XFER。
设计稿 `docs/v3/HOST_FILE_PASTE.md`。

### 4.1 整条通路

```
GUI framebuffer view 拦 Cmd+V → 读 NSPasteboard file URLs
  → IPC clipboard.paste-files → VMHost 子进程
  → FilePasteBridge.handlePasteFiles(urls)
  → 每个 url 串行: vdagent.sendFileXferStart → 等 CAN_SEND_DATA → 流 chunks → 等 SUCCESS
  → 返回 (成功 / 跳过 / 失败) 汇总 → GUI 进程发原生 UNUserNotification
```

落点是 **guest `~/Downloads`** (spice-vdagent 默认目录), 不是当前焦点目录。

> 拦截条件 (GUI 侧 `FramebufferHostView.keyDown`): `macStyleShortcuts=true` + Cmd 单按
> (排除 Cmd+Opt / Cmd+Shift / Cmd+Ctrl) + NSPasteboard 有 file URLs。三条全过才吃掉这次
> Cmd+V; 任一不过走老的文本粘贴路径。

### 4.2 协议常量与超时 (照实际代码)

- **chunk 大小硬约束**: `VdagentClient.fileXferChunkSize = 2000` 字节。SPICE upstream
  `VD_AGENT_MAX_DATA = 2048`, 减 chunk header (8B) + message header (20B) + DATA id/size (12B)
  = 2008, 取 2000 保守。**禁止放大** (会让 spice-vdagent 解码失败)。
  - 1 MiB 文件需 ~525 chunks, 1 GiB 需 ~537K chunks。
- **`FilePasteBridge.maxFileSizeBytes = 4 GiB`**: 单文件软上限, 超过 skip + 引导走共享目录。
- **`canSendTimeoutSec = 30`**: 等 guest 回 `CAN_SEND_DATA` 上限 (探 guest spice-vdagent 是否在线);
  超时报 "guest 端 spice-vdagent 可能未安装或未启"。
- **`finalStatusTimeoutSec = 600`**: 等终态 (SUCCESS / 错误) 上限。大文件按 50 MiB/s 估:
  4 GiB ~ 80s, 600s 留余量。

FILE_XFER wire (`VdagentClient`):
- `START` body = `id(u32)` + GKeyFile 文本 `[vdagent-file-xfer]\nname=<basename>\nsize=<bytes>\n`。
- `DATA` body = `id(u32)` + `size(u64, 本 chunk)` + payload。
- `STATUS` 双向 = `id(u32)` + `result(u32)`; result 枚举: `canSendData=0 / cancelled=1 /
  error=2 / success=3 / notEnoughSpace=4 / sessionLocked=5 / vdagentNotConnected=6 / disabled=7`。

### 4.3 边界

- **文件夹**: skip + 报 "暂不支持文件夹, 请先压缩"。
- **单文件 > 4 GiB**: skip + 报 "请走共享目录"。
- **文件不存在 / stat 失败 / 读取大小失败**: skip。
- **guest 禁用 FILE_XFER** (caps bit 13 置位): 全部 fail, 报 "guest 端 FILE_XFER 已禁用"。
- **多文件串行不并发**: vdagent socket 单 client + SPICE chunks 不可 interleave。
- **v1 不支持中途取消**。

### 4.4 同步实现 (不走 async/await 流式)

整 pipeline 包在 `Task.detached` 里, 内部用 `DispatchSemaphore.wait(timeout:)` (kernel timer)
等 STATUS, 而非 async `Task.sleep`。原因 (代码注释): 在 IPC dispatch 的 `sem.wait()` GCD 线程
+ `@MainActor` Task 跨界栈下, `Task.sleep` 永远不 fire (cooperative pool 饥饿)。每个 transfer id
一个 `TransferSlot` 信号量邮箱, vdagent callback 写、`waitNextStatus` 读。

### 4.5 Windows 文件剪贴板 (UTM 风格, 独立通路)

实现: `app/Sources/HVMDisplayQemu/HVMFileClipboardBridge.swift`。仅 **Windows guest** 启用
(`config.guestOS == .windows`), helper EXE 只有 Win ARM64 build。

跟 §4.1 的 FILE_XFER (落 `~/Downloads`) 不同, 这条是 paste-where-you-paste:

```
NSPasteboard file URLs → PasteboardBridge.onFileURLs → HVMFileClipboardBridge.publishFiles
  1. QGA cleanup staging dir (> 24h TTL)
  2. QGA mkdir  C:\ProgramData\HVM\clipboard\
  3. 每个 url QGA push 到 staging dir (文件名 sanitize)
  4. JSON 帧 {"op":"set-clipboard","paths":[...]} → guest hvm-guest-helper.exe
     → OleSetClipboard + CF_HDROP 设 Win user clipboard
```

要点:
- chardev `com.hellmessage.hvm-clipboard.0`, single-client (HVM 作 client), JSON length-prefix
  framing (4-byte BE u32 length + body), 跟 helper crate `protocol.rs` 对齐, 单帧 ≤ 32 MiB。
- 文件名 `sanitize`: Win 非法字符 `: / \ < > " | ? *` → `_`, 截 200 字符, 防 traversal。
- **单文件 1 GiB 软上限** (`maxFileSizeBytes`, 比 FILE_XFER 4 GiB 严, 剪贴板期望 snappy)。
- staging 文件 TTL 24h, `publishTimeoutSec = 600`。
- helper 没响应是常态 (未装 / 未启), 已上传项移到 failed (没设 clipboard 用户也 paste 不到)。
- 连接断了不报错, 5s 周期 retry 重连。

---

## 5. 文件传输 (qemu-guest-agent push/pull)

实现: `app/Sources/HVMQemu/QgaFile.swift`。走 `<uuid>.qga.sock` (virtio-port
`org.qemu.guest_agent.0`), 与 `QgaExec` 共用通路, 但每次 push/pull 用独立连接 (不持久化)。

### 5.1 API

- **`QgaFile.push(socketPath:srcLocal:dstRemote:...)`**: host → guest。`guest-file-open` (mode
  `wb`) → 循环 `guest-file-write` (默认 1 MiB chunk, base64+JSON 封装, `guestFileWriteAll`
  兜短写) → `guest-file-flush` → `guest-file-close`。直接覆盖 dstRemote。
- **`QgaFile.pull(socketPath:srcRemote:dstLocal:...)`**: guest → host。`guest-file-open` (mode
  `rb`) → `guest-file-seek` (SEEK_END 拿 total, 拿不到标 nil) → 循环 `guest-file-read` (eof
  停)。写到 `.<name>.hvm-tmp.<hex8>` 再 rename, 中断不留半成品 (本地 rename atomic)。

### 5.2 性能 / 边界

- 实测 **8-12 MB/s** 量级 (base64 + JSON + unix socket 1 MiB chunk), 适合 < 100 MiB 偶发传输。
- **软警告 100 MiB / 硬上限 4 GiB** 由调用层 (CLI / GUI) 把关, `QgaFile` 本身不做大小校验。
- 单文件, 不递归。
- 配套: VM 在跑 + qemu-ga 已 attach (Win UTM Guest Tools / Linux `apt install qemu-guest-agent`),
  `guest-file-*` 在 qemu-ga blacklist 之外 (默认开放)。

### 5.3 后续方向: 统一迁 vdagent

CLAUDE.md 记: host → guest 文件传输应**统一走 vdagent file_xfer** (~50 MB/s) 替代当前 QGA
通路 (`FileTransferDialog` 还走 QGA, 1-10 MB/s)。当前暂保留两条通路, v1.1 决策合并。

---

## 6. vdagent 单 socket 多协议复用

`<uuid>.vdagent.sock` 是 single-client chardev (`-chardev server=on`), 必须由 VMHost **唯一持有**
一个 `VdagentClient` 实例 (`QemuHostState.shared.vdagent`)。三个上层 bridge 共享它, 各占不同
callback slot, 互不抢:

| bridge | 用途 | vdagent callback slot |
|--------|------|------------------------|
| `PasteboardBridge` | 文本 / 图片剪贴板 | `onClipboardTextReceived` |
| `FilePasteBridge` | Cmd+V 文件粘贴 (FILE_XFER) | `onFileXferStatus` |
| (`VdagentClient` 自身) | 显示器分辨率 MONITORS_CONFIG | — (`sendMonitorsConfig`) |

启动顺序 (`QemuHostEntry`):
1. `VdagentClient.connect()` (single-client, 唯一持有);
2. `PasteboardBridge` 按 `config.clipboardSharingEnabled` install;
3. `FilePasteBridge` **lazy install** — 第一次 `clipboard.paste-files` IPC 请求到达时才创建
   (`filePasteBridge == nil` 守卫) + `install()`。

> `SpiceWebdavServer` (共享目录) 和 `HVMFileClipboardBridge` (Win 文件剪贴板) 走**各自独立的
> chardev / socket**, 不复用 vdagent socket。"共享 vdagent 实例" 仅指 vdagent 通路内的
> Pasteboard / FilePaste 两个 bridge。

`VdagentClient` 内部 `queue` (serial DispatchQueue) 串行所有 write, 多 bridge 并发调用安全;
长 message 切多 chunk (chunk body ≤ 2048), 接收端 read loop 自动 reassembly。

---

## 7. 测试 / 调试入口

所有验证走 `hvm-dbg` (CLAUDE.md 调试约束: 禁 osascript UI scripting)。

### 7.1 共享目录 (WebDAV)

- **`hvm-dbg webdav-test`** — 离线单测协议层 (mux frame / HTTP 解析 / 路径 escape 防护)。
- **`hvm-dbg webdav-serve --listen`** — 起 `SpiceWebdavServer` 监听本地 socket (`listenMode=true`,
  HVM 作 server bind+listen+accept), 给 curl / Python WebDAV client 做端到端测。

> 路径安全 (`toHostURL` / `composeDest`) 改动必须补 fuzz 覆盖 escape 场景 (CLAUDE.md 硬约束)。

### 7.2 Cmd+V 文件粘贴

- **`hvm-dbg paste-files <vm> --file ...`** — 模拟整条 FILE_XFER 通路 (server 端走相同
  `clipboard.paste-files` IPC), 绕过 framebuffer view 的 NSPasteboard 拦截, 不依赖真鼠标 Cmd+V。

### 7.3 文件传输 (QGA)

- **`hvm-dbg file push <vm> --src ... --dst ...`** / **`hvm-dbg file pull <vm> --src ... --dst ...`**
  — 走 `QgaFile.push` / `pull` 单文件传输。

### 7.4 剪贴板 / 验证建议

- 验证 guest 内文件是否落地 → 优先 `hvm-dbg exec` (qemu-guest-agent 跑命令拿 stdout), 不依赖 OCR。
- 验证 framebuffer → `hvm-dbg screenshot --output X.png` + 肉眼 Read。

---

## 8. 关键约束速查 (硬约束, 改代码前必读)

| 约束 | 出处 |
|------|------|
| WebDAV 协议固定 SPICE WebDAV over virtio-serial, 不走 9p / virtiofs / SMB | §2 |
| WebDAV server 在 Swift 进程内自实现, 不链 libspice-server / libphodav, 不加 `--enable-spice` | §2.3 |
| `toHostURL` / `composeDest` 必须拒 `..` / `.` / 空段 + symlink follow 后越界拒, 改动加 fuzz | §2.4 |
| 共享目录 name 限 `[a-zA-Z0-9_-]{1,32}`, hostPath 必须绝对路径 + 真实存在 | §2.5 |
| 空 `sharedFolders` 不起 server; running 改 `sharedFolders` 拒 (`bundle.busy`); 起失败 fail-soft | §2.6 |
| 改 `sharedFolders` 必走加密分流 (saveConfig), 禁直接 BundleIO.save | §2.6 |
| `fileXferChunkSize = 2000` 字节, **禁止放大** | §4.2 |
| FILE_XFER 超时 CAN_SEND_DATA 30s / 终态 600s; > 4 GiB skip; 文件夹 skip | §4.2 / §4.3 |
| vdagent 单 socket 单 `VdagentClient` 实例, Pasteboard / FilePaste 共享不同 callback slot | §6 |
| FilePasteBridge lazy install (首次 paste-files 请求时) | §6 |
| Win 文件剪贴板单文件 1 GiB 软上限; JSON 帧 ≤ 32 MiB | §4.5 |
| QGA 文件传输软警告 100 MiB / 硬上限 4 GiB (调用层把关) | §5.2 |
| guest 端 spice-webdavd / spice-vdagent / qemu-ga 外置, 不自家 build | §2.7 |

---

## 相关文件

- `app/Sources/HVMQemu/SpiceWebdavServer.swift` — 共享目录 server + WebDavHandler
- `app/Sources/HVMDisplayQemu/VdagentClient.swift` — spice-vdagent client (剪贴板 + FILE_XFER + MONITORS_CONFIG)
- `app/Sources/HVMDisplayQemu/PasteboardBridge.swift` — 文本 / 图片剪贴板桥
- `app/Sources/HVMDisplayQemu/FilePasteBridge.swift` — Cmd+V 文件粘贴 (FILE_XFER)
- `app/Sources/HVMDisplayQemu/HVMFileClipboardBridge.swift` — Win 文件剪贴板 (UTM 风格)
- `app/Sources/HVMQemu/QgaFile.swift` — QGA 文件 push/pull
- `app/Sources/HVMCore/Paths.swift` — 全部 socket 路径派生
- `app/Sources/HVMBundle/VMConfig.swift` — `SharedFolderSpec` (sanitizeName)
- `app/Sources/HVM/QemuHostEntry.swift` — bridge 启动 / 复用 wiring
- 设计稿: `docs/v3/SHARED_FOLDER.md` / `docs/v3/HOST_FILE_PASTE.md` / `docs/v3/FILE_COPY.md`
