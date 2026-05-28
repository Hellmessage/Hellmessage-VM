# Host → Guest 文件剪贴板 (UTM 风格 paste-where-you-paste)

**状态**: 设计稿 (待评审)
**关联**:
  - [HOST_FILE_PASTE.md](HOST_FILE_PASTE.md) — Cmd+V 文件粘贴, 走 SPICE FILE_XFER 落 Downloads (现有)
  - [HOST_FILE_DRAG.md](HOST_FILE_DRAG.md) — 拖放, 同上 (现有)
  - [HOST_IMAGE_CLIPBOARD.md](HOST_IMAGE_CLIPBOARD.md) — 图片剪贴板, 走 SPICE vdagent CLIPBOARD mime=2 (现有)
**日期**: 2026-05-28

---

## 1. 目标 + 范围

### 1.1 用户故事
> "我在 macOS Finder Cmd+C 一个文件, 切到 Windows VM, 在 Explorer 桌面 Ctrl+V → 文件出现在桌面; 在 Telegram 输入框 Ctrl+V → 图片作为 Telegram 附件发送; 在 Word Ctrl+V → 嵌入文档. 一次复制, 哪里粘贴都按 app 自己的理解处理 (跟 UTM / Parallels / VMware Fusion 一致)."

### 1.2 关键发现 (探针实验 2026-05-28)

SPICE 协议本身有 `VD_AGENT_CLIPBOARD_FILE_LIST = 6` mime, 但 **UTM Guest Tools 里的 `vdagent.exe` 实测不响应** (host 端 GRAB 广告 mime=6, guest 完全不 REQUEST). 不是协议错配, 而是 vdagent.exe **不实现 FILE_LIST 处理逻辑**.

所以本提案**不走 SPICE vdagent**, 改成 HVM 自家 guest helper service + 独立 virtio-serial channel.

### 1.3 做什么

1. **自家 guest helper EXE** (Windows arm64 + x64): 用户态进程, 跑在 user session, 监听 virtio-serial → 收 host 指令 → 调 `OleSetClipboard` + `CF_HDROP` 设 Windows 用户剪贴板
2. **host 端**: NSPasteboard 监听文件 URL → 走 QGA 把文件上传到 guest staging dir → 经新 virtio-serial channel 通知 helper "设剪贴板指向这些路径"
3. **零用户操作安装**: HVM 首次启动 Windows VM 自动检测 + 自动推送 helper EXE + 注册自启 (走现有 QGA 通路, 跟 UTM Guest Tools 共存不冲突)

### 1.4 不做什么 (v1 范围外)

- **Linux guest** — v1 仅 Windows. Linux 走 xclip/wl-copy 是另一条 helper, 推 v2 (协议层共用, 实现独立)
- **macOS guest** — 永不做 (vmnet macOS guest 是 VZ 后端, 没 QEMU virtio-serial)
- **guest → host 反向文件剪贴板** — v1 不做 (Win 内 Cmd+C 文件 → macOS Cmd+V), 推 v3
- **代码签名 EV cert** — 不做. 用户态 EXE 不签名能跑, SmartScreen 第一次有警告 (后续静默自启不再问). 自签 cert 不带 EV 反而让 SmartScreen 更怀疑, 不如不签
- **Microsoft Store 分发** — 不做. 内部分发, 跟 HVM.app 一起 bundle
- **多 user session 支持** — v1 仅 console session (sessionId=1). RDP 多会话同时上线场景不接

---

## 2. 架构总览

```
┌──────────────────────────────────────────┐         ┌──────────────────────────────────────────┐
│ macOS HVM (host)                         │         │ Windows guest (user session 1)            │
│                                          │         │                                            │
│  AppKit Cmd+C file in Finder             │         │   hvm-guest-helper.exe (auto-started)     │
│             │                            │         │      │                                     │
│             ▼                            │         │      │ readline JSON over                  │
│  PasteboardBridge.poll                   │         │      │ \\.\Global\com.hellmessage.        │
│             │                            │         │      │      hvm-clipboard.0                │
│             │ file URLs?                 │         │      │                                     │
│             ▼                            │         │      ▼                                     │
│  HVMFileClipboardBridge                  │         │   "set-clipboard"                          │
│  ├─ QGA push files (FilePush)            │ ─────→  │   {paths: ["C:\\ProgramData\\HVM\\        │
│  │  to C:\ProgramData\HVM\clipboard\     │  上传    │              clipboard\\foo.png"]}         │
│  ├─ send "set-clipboard" cmd             │  + cmd  │                                            │
│  │  via new chardev                      │         │   OleSetClipboard(IDataObject impl)        │
│  │                                       │         │   ↓                                        │
│  │                                       │         │   Windows clipboard now has CF_HDROP       │
│  ▼                                       │         │   pointing to staged file                  │
│  guest helper reports OK                 │ ←─────  │                                            │
└──────────────────────────────────────────┘         │   User Ctrl+V in Explorer Desktop:        │
                                                     │     Explorer reads CF_HDROP → copies file  │
                                                     │     from staging → user Desktop            │
                                                     │                                            │
                                                     │   User Ctrl+V in Telegram:                 │
                                                     │     Telegram reads CF_HDROP → opens file   │
                                                     │     as image attachment                    │
                                                     └──────────────────────────────────────────┘
```

### 关键设计点

| # | 选择 | 理由 |
|---|-----|-----|
| 1 | 新 virtio-serial chardev `com.hellmessage.hvm-clipboard.0` | 不抢 vdagent socket, 跟 UTM Guest Tools 完全独立 |
| 2 | QGA 上传文件 (复用现有 QgaFile.push) | 已经稳定; 走 SYSTEM 上下文写 `C:\ProgramData\` 是允许的 |
| 3 | helper 跑在 user session (sessionId=1) | Windows clipboard 是 per-session, SYSTEM 设的看不到 |
| 4 | 文件 staging 在 `C:\ProgramData\HVM\clipboard\` | world-readable, 任何 user-session app 都能 paste 读 |
| 5 | 自动安装走 QGA + 注册表自启 | 用户零操作, 跟现有 unattend.iso 一样无感 |
| 6 | helper 用 Rust + gnullvm cross-compile | 单静态 EXE, 无 DLL deps, 从 macOS 也能 cross-build |
| 7 | 不签名 | 用户态 EXE 不强制; SmartScreen 仅首次启动可能弹 (自启路径绕过) |

---

## 3. 选型对比

### 3.1 备选方案

| 方案 | 通路 | guest 端要求 | 工程量 | 选/不选 |
|-----|------|-------------|--------|---------|
| **A. 自家 helper + virtio-serial (本稿)** | 新 chardev + JSON 协议 + 文件经 QGA 上传 + helper 设 CF_HDROP | helper EXE 自动安装, 不需 driver | 2-3 周 | ✓ **选** |
| B. fork spice-vdagent for Windows 加 FILE_LIST | SPICE 协议 mime=6 | 用户得装我们 fork 版本的 UTM Guest Tools | 大 (需要 fork 维护 + 升级追 upstream) | ✗ 长期维护成本高 |
| C. 自家 Windows kernel driver | virtio 自家 driver 直接挂 clipboard | EV signing certificate + Microsoft attestation | 极大 (driver 签名要 $300+ + 攻坚) | ✗ 杀鸡用牛刀 |
| D. SPICE WebDAV mount + clipboard 指向 mount 路径 | 复用现有 WebDAV server | guest 需挂 share, 重启 lost | 小 (协议层都有) | ✗ "粘贴" 体验跟 native 不一致 (mount 路径用户能感知) |
| E. 让用户手动安装第三方"clipboard sharing" tool (e.g. Synergy/Barrier) | 跟 HVM 完全独立 | 用户自购自装 | 零 | ✗ 等于不解决问题 |

### 3.2 为什么不走 SPICE FILE_LIST (mime=6)

- 实测 UTM Guest Tools vdagent.exe **不实现**: 探针实验 (2026-05-28) 显示 host 端发 GRAB 广告 mime=6, guest 完全 silently 忽略, 不发 REQUEST. 不是协议错配, 是 guest 端实现缺失
- fork vdagent 维护代价: 跟上游 spice-vdagent 每次升级都要 rebase patch, 加 ARM64 Win 构建 chain 维护; 而且 UTM 用户已经习惯了 UTM Guest Tools 自家的版本号 (改 fork 名字让用户疑惑)
- 走自家通路反而更解耦 — 跟 vdagent / qga 都是平行 channel, 任何一条断了不影响其他

---

## 4. 实现要点

### 4.1 virtio-serial 新 chardev

QemuArgsBuilder 在 Windows guest argv 末尾追加 (跟现有 vdagent / qga / webdav chardev 同款 unix socket 模式):

```
-chardev socket,id=hvmclipboard,
         path=<run>/hvm-clipboard.sock,
         server=on,wait=off
-device virtserialport,bus=vsp0.0,chardev=hvmclipboard,
         name=com.hellmessage.hvm-clipboard.0
```

socket 路径: `HVMPaths.hvmClipboardSocketPath(for: vmId)`, host 进程作 client 连接 (single-client, 跟 vdagent 同款).

guest 内 Windows virtio-serial 驱动 (UTM Guest Tools 自带) 把这个 virtserialport 映射成设备路径:
`\\.\Global\com.hellmessage.hvm-clipboard.0`

helper EXE 用 CreateFile 打开这个路径读写 (跟 SPICE vdagent 走的同款 API).

### 4.2 协议 (host ↔ helper)

length-prefix framing (跟现有 HVMIPC 同款: 4-byte BE u32 length + JSON body).

**Host → Helper requests**:
```json
{"id":"...", "op":"ping"}
{"id":"...", "op":"set-clipboard", "paths":["C:\\ProgramData\\HVM\\clipboard\\foo.png"]}
{"id":"...", "op":"clear-clipboard"}
```

**Helper → Host responses**:
```json
{"id":"...", "ok": true, "version": "1.0.0"}
{"id":"...", "ok": false, "code":"clipboard.access_denied", "message":"..."}
```

helper 不发主动消息 (没 "guest 端用户复制了什么" 反向, v1 范围外).

### 4.3 host 端逻辑 (HVMFileClipboardBridge)

新增模块 `HVMDisplayQemu/HVMFileClipboardBridge.swift`, 跟 PasteboardBridge 平行:

```swift
@MainActor
public final class HVMFileClipboardBridge {
    init(clipboardSocketPath: String, qgaSocketPath: String, vmId: UUID)
    func start()  // open chardev socket + register NSPasteboard callback
    func stop()
    private func onPasteboardFiles(_ urls: [URL])  // QGA push + send set-clipboard
}
```

流程:
1. PasteboardBridge.pollHostPasteboard 检测到 file URLs → 调 `HVMFileClipboardBridge.onPasteboardFiles(urls)`
2. onPasteboardFiles:
   - skip dirs / >4 GiB 文件 (跟 FILE_XFER 同边界)
   - 每个 url: 算 guest staging path: `C:\ProgramData\HVM\clipboard\<sanitized-name>`
   - 走 QgaFile.push 上传 (并发, max 4 streams)
   - 所有上传完后, 发 `{op:"set-clipboard", paths: [...guest paths]}` 给 helper
   - helper 回 ok → log success; fail → 走 ErrorPresenter + 通知
3. **LRU 清理**: 每次 set-clipboard 前删 `C:\ProgramData\HVM\clipboard\` 下 mtime > 24h 的旧文件 (限 100 files / 1 GB 上限)

### 4.4 guest helper EXE

**语言**: Rust (`hvm-guest-helper`).
- Cross-compile from macOS: `cargo build --target aarch64-pc-windows-gnullvm --release` (LLVM linker, 无需 MSVC, mac 可直接构建)
- 单静态 EXE, 无 DLL deps. 大小 ~500 KB
- arm64 + x64 两 target build

**依赖**: 只用 windows-rs (官方 Win32 binding) + serde_json. 不引重型框架.

**功能**:
1. main loop:
   - 打开 `\\.\Global\com.hellmessage.hvm-clipboard.0`, 失败 retry 5s
   - 读 length-prefix JSON 帧
   - 分派 op 处理
   - 写回 response
2. `set-clipboard` 处理:
   - 校验所有 path 存在 + readable
   - 构造 `CF_HDROP` 数据结构 (DROPFILES + 路径列表)
   - `OpenClipboard(NULL)` + `EmptyClipboard()` + `SetClipboardData(CF_HDROP, ...)` + `CloseClipboard()`
3. `clear-clipboard`: `OpenClipboard` + `EmptyClipboard` + `CloseClipboard`
4. `ping`: 立即回 ok + version

**自动重连**: 主循环包 retry, virtio-serial socket 断开 (host VMHost 重启) 时 5s 后重连.

**日志**: 写 `%LOCALAPPDATA%\HVM\helper.log` (滚动 10 MB), 给调试.

### 4.5 helper 自动安装

HVM 端 (QemuHostEntry / 一次性安装代码):

1. **检测**: VM 启动 + QGA 就绪后, 走 QGA exec `if exist C:\ProgramData\HVM\.helper-installed-v1`. 如已安装 (marker 存在) → 跳过.
2. **首次安装**:
   - QGA push: `hvm-guest-helper.exe` → `C:\Program Files\HVM Guest Helper\hvm-guest-helper.exe`
   - QGA exec: 创建 `C:\ProgramData\HVM\clipboard\` (world-writable)
   - QGA exec: 写注册表 `HKLM\Software\Microsoft\Windows\CurrentVersion\Run\HVMGuestHelper = "C:\Program Files\HVM Guest Helper\hvm-guest-helper.exe"` (HKLM 给所有 user 用; helper 进程自己跑在调用 user 的 session)
   - QGA exec: 用 `schtasks /run` 立刻拉一次 (不必等用户重新登录)
   - QGA exec: touch `C:\ProgramData\HVM\.helper-installed-v1`
3. **升级**: helper 自带 version. 启动时跟 `\helper-installed-v1` marker 对比 (写 v2 时改 marker 名). HVM 改 marker → 触发重装.

### 4.6 文件 staging 目录策略

`C:\ProgramData\HVM\clipboard\` — world-writable + world-readable.

- 文件名清洗: 替换 `:/\\<>"|?*` → `_`. 防 Windows 非法字符
- 重名处理: 如 `foo.png` 已存在但 SHA256 不同 → 改名 `foo (1).png` / `foo (2).png` / ...
- LRU 上限: 100 files 或 1 GB. 触限时删最老 mtime
- 周期清理: 每次 set-clipboard 前扫描, 删 mtime > 24h 的

### 4.7 跟现有路径的交互

| 现有 | 行为 |
|-----|------|
| PasteboardBridge (text + image 走 vdagent) | 不变. text/image 继续走 vdagent CLIPBOARD mime=1/2 |
| HOST_FILE_PASTE Cmd+V 截获 (FILE_XFER → Downloads) | **保留**. 用户期望"显式 Cmd+V 在 VM 窗口 = 给 VM 一个文件去 Downloads", 跟"我复制了文件准备到处粘贴"是不同动作 |
| HOST_FILE_DRAG 拖放 (FILE_XFER → Downloads) | **保留**. 同上 |
| 新 HOST_FILE_CLIPBOARD | **新增**. 隐式同步: 用户 Cmd+C → 后台上传 → guest 任意 Ctrl+V 粘贴文件 |

**用户感知**:
- Cmd+C 文件 (Finder) → 看似什么都没发生, 但后台已上传到 guest
- Ctrl+V 在 guest 任意 app → 文件出现 (按 app 理解: Explorer 复制文件, Telegram 发图片, Word 插入)

### 4.8 跟 HOST_FILE_PASTE / HOST_FILE_DRAG 的语义重叠

3 条通路语义对比:

| 通路 | 触发 | 落到哪 | 何时用 |
|-----|------|-------|-------|
| **HOST_FILE_CLIPBOARD (本提案)** | NSPasteboard 有 file URL → 后台自动上传 | guest 用户当前粘贴的 app 决定 | 大多数日常 |
| **HOST_FILE_PASTE (Cmd+V on framebuffer)** | 用户在 VM 窗口里 Cmd+V | guest `~/Downloads` | 想显式 "送给 VM 一个文件" |
| **HOST_FILE_DRAG (拖放)** | 用户拖文件到 VM 窗口 | guest `~/Downloads` | 同上, 拖更直观 |

设计上 3 条共存. 用户可能"复制后既看到 guest Downloads 多了文件 (Cmd+V 触发), 又能在 Telegram Ctrl+V 粘贴 (clipboard 触发)" — 两次操作两个效果, 不互斥.

---

## 5. 安全 / 隐私边界

- 文件传输只在 host ↔ guest 之间 (virtio-serial), 不经网络
- `C:\ProgramData\HVM\clipboard\` 是 world-readable — guest 内所有用户 + 进程能读 (跟 Windows 默认 ProgramData 权限一致). 不放敏感文件场景: 用户复制 ssh key / password file → guest 任意 user 能读. 风险写明在 docs/v1 章节, 用户自负
- helper EXE 跑在 user session, 操作 user clipboard — 跟用户自己 Ctrl+C 等价权限, 不提权
- LRU 24h 清理 — staging 文件不会无限累积, 用户重启后老文件清光

---

## 6. PR 拆解

| PR | 范围 | 时间盒 |
|----|-----|-------|
| **PR-1** 自家 helper EXE | Rust `hvm-guest-helper` crate, scaffold + virtio-serial 读写 + JSON 协议 + ping/set-clipboard/clear-clipboard 三 op. Cross-compile arm64 + x64 from macOS. 跑独立测试 (mock chardev) | 4 天 |
| **PR-2** host 端 bridge | `HVMDisplayQemu/HVMFileClipboardBridge.swift`, virtio-serial chardev client (复用 SocketClient 模式) + JSON 编解码 + 请求路由. QemuArgsBuilder 加 chardev argv. PasteboardBridge 加 onFileURLs 回调 | 3 天 |
| **PR-3** 文件上传通路 | HVMFileClipboardBridge 集成 QgaFile.push 并发上传 + 路径 sanitization + LRU 清理调度. 失败处理 (单文件失败不阻其他) | 2 天 |
| **PR-4** helper 自动安装 | QemuHostEntry 启动后 detect marker + push EXE + 写注册表 + schtasks /run + touch marker. virtio-win 模式同款 | 2 天 |
| **PR-5** 测试 + 文档 | hvm-dbg `clipboard-files` 子命令模拟 NSPasteboard file URLs (自动化测). docs/v3/HOST_FILE_CLIPBOARD.md → 代码已合入. CLAUDE.md 加约束. docs/v1 写现状 | 2 天 |

**总计**: ~13 工作日 (2.5-3 周). 比预估 2-3 周略保守.

---

## 7. 测试方案

### 7.1 协议层 (host ↔ helper 独立)
- mock virtio-serial 用 socketpair, helper 跑在子进程, host 走 SocketClient 发 ping
- 验 set-clipboard 走通 + helper 调 OleSetClipboard 成功
- 跑 cargo test (helper crate) + Swift Bridge mock test

### 7.2 真机 e2e (Win VM `测试`)
1. helper 自动安装跑通: 启 Win VM → 30s 后检查 helper 进程存在
2. 文件粘贴到 Explorer 桌面: Mac Cmd+C `/tmp/foo.png` → guest Ctrl+V on Desktop → 桌面出现 `foo.png`
3. 图片粘贴到 Telegram: 同上 → 切 Telegram 输入框 → Ctrl+V → 图片作为附件
4. 多文件: Cmd+C 3 个文件 → Explorer paste → 3 个文件全到
5. 大文件: Cmd+C 100 MB 文件 → 上传期间用户感知 (要不要 progress UI?)

### 7.3 hvm-dbg
- `hvm-dbg clipboard-files set --vm 测试 --file X --file Y` — 模拟 NSPasteboard file URLs 触发整条通路 (绕过真实 macOS Cmd+C)
- `hvm-dbg clipboard-files clear --vm 测试` — 触发 clear-clipboard
- `hvm-dbg clipboard-files ping --vm 测试` — 验 helper 健康度

---

## 8. 风险 + 待验证

### P0 (上线前必过)
- **P0-1** helper EXE 跨 Windows 版本兼容: Win10 1809+ / Win11 / arm64 + x64 全测
- **P0-2** schtasks /run + Run 注册表跑通 — user session 拉起 helper
- **P0-3** virtio-serial chardev 在 Windows 端正确暴露为 `\\.\Global\com.hellmessage.hvm-clipboard.0`. 需要 UTM Guest Tools 自带的 virtio-serial driver 通用支持 (默认是, 但要验证)
- **P0-4** 大文件上传中 user 又 Cmd+C 新文件: 旧的 set-clipboard 是否 cancel?
- **P0-5** helper 异常崩溃后自启 — 注册表 + Task Scheduler 第二条兜底

### P1 (上线后跟踪)
- **P1-1** 同时多 user session (RDP) 的 clipboard 隔离 — 当前 helper 只跑 console session, RDP 用户的 clipboard 不同步, v1 接受
- **P1-2** clipboard 内容跟 vdagent text/image 互相覆盖的语义 — 现 vdagent text/image 跟 helper file 互不影响 (不同 mime); 但用户 Cmd+C 同时有文件 + 文本时行为
- **P1-3** Linux guest 端实现 (v2)

### 已知妥协
- 不支持 v1 GUI 升级 helper: 改 marker 名让用户重启 VM 自动重装
- 不支持 RDP 多 session
- staging dir world-readable — 不建议用本通路传敏感文件

---

## 9. 未决事项 (Decisions)

| ID | 议题 | 当前默认 | 决策时机 |
|----|------|---------|---------|
| D1 | helper 语言 | Rust + windows-rs + cross-compile gnullvm | 设计稿 ✓ |
| D2 | helper 签名 | 不签 (自启路径绕过 SmartScreen) | 设计稿 ✓ |
| D3 | helper 分发 | 内置 HVM.app Resources/, QGA 推 + 注册表自启 | 设计稿 ✓ |
| D4 | 文件 staging 路径 | `C:\ProgramData\HVM\clipboard\` | 设计稿 ✓ |
| D5 | LRU 上限 | 100 files / 1 GB / 24h | 设计稿 ✓ |
| D6 | Cmd+V 截获跟 clipboard 通路共存还是择一 | 共存 (语义不同) | 设计稿 ✓ |
| D7 | 大文件上传进度 UI | v1 不做 (后台 silent, 上传慢时用户感知是 "Ctrl+V 后稍等") | 设计稿 ✓ |
| D8 | guest → host 反向 (Win Cmd+C → Mac Cmd+V) | v3 推后 (需要 helper monitor Win clipboard 变化) | 设计稿 ✓ |
| D9 | Linux guest 支持 | v2 推后 | 设计稿 ✓ |
| D10 | RDP 多 session 支持 | v1 仅 console session | 设计稿 ✓ |
| D11 | helper 升级路径 | v1 改 marker 名重装; v2 加 in-place update | 设计稿 ✓ |
| D12 | 文件名冲突策略 | `foo.png` → `foo (1).png` 同 Windows native | 设计稿 ✓ |

---

## 10. 回写计划 (实现合入后)

- `docs/v1/CLIPBOARD.md` (新建) 加 "文件剪贴板" 节
- `CLAUDE.md` 加约束:
  - HVM Guest Helper 自动安装路径 + marker 文件名格式
  - virtio-serial chardev 命名规范 (`com.hellmessage.*` namespace)
  - 文件 staging 目录权限 + LRU 上限
  - Cmd+V 截获 vs 自动剪贴板同步 共存语义
- 设计稿头部状态改 `代码已合入`, 留底不删

---

## 11. 参考实现

- Windows OleSetClipboard + CF_HDROP: <https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-olesetclipboard>
- virtio-serial Windows driver / port API: <https://github.com/virtio-win/kvm-guest-drivers-windows/tree/master/vioserial>
- spice-vdagent Windows 参考 (虽然没用 FILE_LIST, 但 virtio-serial 打开方式可复用): <https://gitlab.freedesktop.org/spice/win32/vd_agent_service>
- windows-rs crate: <https://github.com/microsoft/windows-rs>
- Rust gnullvm target: <https://github.com/rust-lang/rust/tree/master/library/std/src/sys/pal/windows>
