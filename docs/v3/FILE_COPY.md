# Windows / Linux Guest 文件复制 (QGA file API)

> 状态: **实现中** (2026-05-06) — 代码 PR-A/B/C/D 已合入, 待真机 P0 gate 验证 (R1 qemu-ga `guest-file-*` 是否开放; R5 VMHost 子进程直读 host 文件) + e2e 走通后转 "代码已合入".
>
> 关联文档: [QEMU_INTEGRATION.md](../v1/QEMU_INTEGRATION.md), [HVMQemu/QgaExec.swift](../../app/Sources/HVMQemu/QgaExec.swift) (现有 QGA exec 通路), [HVMQemu/QgaFile.swift](../../app/Sources/HVMQemu/QgaFile.swift) (本提案落地)

## 背景

当前 host ↔ guest **没有任何文件传输通路**:

- VZ 后端: 未启用 `VZSharedDirectory` / virtiofs
- QEMU 后端: argv 不挂 `-fsdev` / `-virtfs` / `-device virtio-9p`; QEMU 编译期已 `--disable-fuse` `--disable-spice`
- 已有 `qemu-guest-agent` 通路 (chardev qga + virtio-serial port `org.qemu.guest_agent.0`), 但仅封装了 `guest-exec` (跑命令拿 stdout/stderr) — 没接 `guest-file-open/write/read/close`
- UTM Guest Tools (Windows guest 装机自带) 已含 ARM64 native `qemu-ga.exe` 服务, 自动 attach 到 `\\.\Global\com.qemu.guest_agent.0`
- 用户实际使用场景: 把一份配置文件 / 安装包 / 小工具拷进 Win VM, 或把 VM 内日志拉回 host. 不是大文件 / 不是高频, 但目前完全做不了

## 目标 + 范围

**做**:

- **host → guest push** 单文件 (任意 binary; 路径由用户指定)
- **guest → host pull** 单文件
- **进度反馈** (字节数 + 百分比), CLI 流式打印
- **后端**: QEMU (Windows / Linux guest, 都依赖 qemu-ga 服务在跑)
- **入口**: `hvm-dbg file push / pull` (CLI) + GUI Sharing 区两个按钮 ("传文件到 VM" / "从 VM 取文件")

**不做**:

- 文件夹递归 (v1) — 用户先 `zip` 后 push, 再 guest 内 unzip. 递归 v2 再加
- VZ 后端 (Linux / macOS guest) — VZ 没接 QGA, 走 `VZSharedDirectory` + virtiofs 是 Apple-native 路线, 单独提案
- 增量 / rsync 算法
- 拖拽进 GUI 主窗口 (drag-drop) — v2 再加
- 写入加密 disk 的特殊处理 — QGA 跑在 guest 进程内, 与底层 LUKS 无关, 透明
- 大文件优化 (>1 GiB 仍能跑, 但 1-10 MB/s 速率, 用户自负)

## 选型对比

| 方案 | 实现 | guest 改动 | 速度 | 工作量 | 选用 |
|---|---|---|---|---|---|
| **A. QGA `guest-file-*`** | 复用 chardev qga 通路, NDJSON 收发 base64 chunk | 零 — UTM Guest Tools 已装 qemu-ga.exe | 1–10 MB/s (base64+JSON 开销) | 小 — 一个 `QgaFile.swift` + IPC + CLI + GUI | ✅ |
| B. virtiofs + virtiofsd | argv 加 `-chardev socket` + virtiofsd 进 .app, guest 内装 winfsp + virtio-win virtiofs.exe | 大 — 重开 virtio-win driver (现 `WindowsUnattend.swift:280` 默认禁), 加装 winfsp + 启 virtiofs service. ARM Win winfsp 签名 / 兼容性坑多 | ~原生 (NVMe 级) | 大 — virtiofsd Rust 二进制打包 + driver 闭环 + 装机流程改造 | ✗ (推后) |
| C. 9p / virtio-9p | argv `-fsdev local + -device virtio-9p-pci` | Windows 无官方 9p driver (Linux 适用) | 中 | 中 (但 Win 不能用) | ✗ |
| D. SMB (host 暴露 share) | host 启 SMB / sharingd, guest 内 `\\host.local` 挂载 | guest 手动配 + 防火墙 + 用户认证 | 网络速度 | 中 | ✗ (不在 HVM 闭环, 用户感知重) |
| E. USB mass storage 挂 raw image | host 把文件写进 raw img, argv 加 usb-storage | guest 必须重启 (USB hotplug 在 QEMU + qemu-ga 不可靠), 一次性 | 快 (一次成型) | 中 | ✗ (重启代价大) |

**选 A**. 理由:

- QGA 通路已落, qemu-ga.exe 已装, **零 guest-side 改动**
- 性能 1-10 MB/s 对偶发小文件 (< 100 MiB) 完全够用; 用户传 ISO 等大文件场景罕见, 罕见时再走 virtiofs (B)
- Linux guest 也开箱可用 (主流发行版包名 `qemu-guest-agent`, 用户在 guest 内 `apt install` 即可)
- B 是长期路线但工程量大, 写进"未决"留给后续单独提案

## 实现要点

### QGA 文件 API 协议

qemu-ga 内置以下命令 (默认启用, `--allow-rpcs` 不需要额外配):

```
guest-file-open  { path: "/abs/path", mode: "r"|"w"|"rb"|"wb"|"a"|"ab" }
                 → return: <int handle>
guest-file-write { handle, buf-b64, count? }
                 → return: { count, eof }
guest-file-read  { handle, count }
                 → return: { count, buf-b64, eof }
guest-file-seek  { handle, offset, whence: 0/1/2 }
                 → return: { position, eof }
guest-file-close { handle }
                 → return: {}
guest-file-flush { handle }
                 → return: {}
```

NDJSON 一行一命令. 参考 [QEMU GA 文档](https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html).

### 模块拆分

**`HVMQemu/QgaFile.swift`** (新增):

```swift
public enum QgaFile {

    /// host → guest push. dst 是 guest 内绝对路径 (Win: "C:\\path\\file.exe"; Linux: "/tmp/x").
    /// progress: 每写一个 chunk 回调一次, bytesSent / totalBytes.
    public static func push(
        socketPath: String,
        srcLocal: URL,
        dstRemote: String,
        chunkSize: Int = 1 * 1024 * 1024,
        timeoutSec: Int = 600,
        progress: ((_ bytesSent: Int64, _ total: Int64) -> Void)? = nil
    ) async throws -> Int64  // 返实际写入字节

    /// guest → host pull.
    public static func pull(
        socketPath: String,
        srcRemote: String,
        dstLocal: URL,
        chunkSize: Int = 1 * 1024 * 1024,
        timeoutSec: Int = 600,
        progress: ((_ bytesRead: Int64, _ total: Int64?) -> Void)? = nil
    ) async throws -> Int64
}
```

复用 `QgaExec.swift` 内 `connectUnix` / `sendJsonLine` / `readJsonLine` (抽到内部 `QgaSocket` helper, `QgaExec` 与 `QgaFile` 共用).

**chunk 选型**: 1 MiB raw → base64 后 ~1.33 MiB JSON → QGA `readJsonLine` 限 16 MiB ✓. 100 MiB 文件 = 100 个 chunk, 每个 RTT ~5-20 ms (本机 Unix socket), 可接受.

**atomicity**: push 写 `<dst>.hvm-tmp.<8>` → close → rename. rename 用 guest-side `guest-exec` 调系统 mv (Win 用 PowerShell `Move-Item -Force`; Linux 用 `mv -f`). 中断 → tmp 残留, 第二次 push 检测同名 tmp 删掉重来.

### IPC 接入

**`HVMIPC/Protocol.swift`** 新增 op:

```swift
case dbgFilePush = "dbg.file.push"   // args: localPath, remotePath
case dbgFilePull = "dbg.file.pull"   // args: remotePath, localPath
```

payload:

```swift
public struct IPCDbgFileTransferPayload: Codable, Sendable {
    public let bytesTransferred: Int64
    public let durationMs: Int64
    public let sha256Hex: String?  // 可选 — 仅当用户传 --verify 才算
}
```

**`app/Sources/HVM/QemuHostEntry.swift`** 加 `handleDbgFilePush` / `handleDbgFilePull`, 跟现有 `handleDbgExecGuest` (L1063) 同模式: 取 `qgaSocketPath`, fileExists 检查, 调 `QgaFile.push/pull`, 失败转 `qga.file_failed` IPCResponse.

进度反馈 v1 不走 IPC stream (复杂度高), 改为: hvm-dbg 子命令在 client 端**轮询本地 src 文件 size + os.Logger 流式打印 "已传 X / Y MB"**. 严格说不是真进度, 是 push 端时间预估 — 但 chunk 是同步的, 用户感知 OK. v2 真要 stream 再说.

### CLI: hvm-dbg 子命令

**`app/Sources/hvm-dbg/Commands/FilePushCommand.swift`** + **`FilePullCommand.swift`** 新增:

```
hvm-dbg file push <vm> --src /local/path --dst 'C:\Windows\Temp\x.exe' [--timeout 600]
hvm-dbg file pull <vm> --src 'C:\path\file.log' --dst /local/path [--timeout 600]
```

按 `app/Sources/hvm-dbg/HvmDbg.swift` 现有 subcommand 注册风格挂上 (跟 ExecGuest 平级). 提示规范:

- 启动: `[file-push] /local/x.iso → C:\\Windows\\Temp\\x.iso (104857600 B)`
- 进度: `\r[file-push] 25% (26.2/104.8 MB) ...` (TTY 时); 非 TTY 每秒一行
- 完成: `[file-push] done in 12.4s (8.4 MB/s)`
- 失败: `[file-push] failed at 32.1 MB: qga.file_failed (...)`

### GUI: Sharing 区按钮

**`app/Sources/HVM/UI/Content/DetailBars.swift`** 的 `sharingSection` (L457) 在"剪贴板共享"toggle 下加两个按钮 (套 `PrimaryButtonStyle`):

```
┌─ Sharing ──────────────────────────────────┐
│ ☑ 剪贴板共享 (host ↔ guest)                │
│ [传文件到 VM]  [从 VM 取文件]               │
└────────────────────────────────────────────┘
```

- "传文件到 VM" → `NSOpenPanel` 选 host 文件 → 弹 `HVMModal` "目标路径" 输入框 (默认 `C:\\Users\\hvm\\Downloads\\<basename>` Win / `/tmp/<basename>` Linux, 按 guestOSType 切) → "开始" → 走 IPC `dbg.file.push` → modal `closeAction = nil` 期间显示进度 + 完成切 done 态显 "已传 X MB, 用时 Ys"
- "从 VM 取文件" → 弹 `HVMModal` "源路径" 输入框 → 选好 `NSSavePanel` 落地 → 走 IPC `dbg.file.pull` → 同样 modal 进度

VM 未运行 / qga socket 不存在时按钮 disabled + 文案 "VM 未运行 / qemu-ga 服务未连"

`hvmProbe` ID 命名:

- `dialog.fileTransfer.input.remotePath`
- `dialog.fileTransfer.button.start`
- `dialog.fileTransfer.button.cancel` (取消按钮 v1 仅 close modal, 不发"中断"信号 — 后台传输继续跑完留 tmp; 见 D5)
- `detail.sharing.button.pushFile` / `detail.sharing.button.pullFile`

## 风险与待验证项

| 编号 | 风险 | 验证方式 | 阻断 |
|---|---|---|---|
| **R1** | UTM Guest Tools 装的 qemu-ga.exe 是否启用 guest-file-* (默认 vs blacklist) | 装机后跑 `hvm-dbg exec-guest --ps "qemu-ga --version"` 拿版本; 试一次 `guest-file-open` 看返 handle 还是 `GenericError`. blacklist 见 qemu-ga `--blacklist` 启动参数, 默认空, UTM 装包脚本要确认无强制 disable | **P0** |
| **R2** | chunk 1 MiB / RTT 实测带宽 | 100 MiB 文件 push, 测时间 → 期望 8-12 MB/s. < 1 MB/s 说明 qga 通路有瓶颈, 调 chunk 或换 virtiofs | P1 |
| **R3** | 远端路径 UTF-8 vs Windows-CP encoding | 测 `C:\Users\张三\test.txt` 中文路径 push/pull. qemu-ga JSON 协议是 UTF-8, Win 内部用 UTF-16 — qemu-ga 应自动转, 验一次 | P1 |
| **R4** | 加密 VM 影响 | 加密 VM 启动 + push 文件, 验跟明文 VM 行为一致 (QGA 走 virtio-serial, 不经 disk) | 已论证 (无影响) |
| **R5** | GUI 沙盒 NSOpenPanel URL 传给 VMHost 子进程 read | HVM main 是 entitled non-sandboxed app (无 `com.apple.security.app-sandbox`), `Process` 启动 VMHost 子进程同样可读. 但 NSOpenPanel 返的 security-scoped URL 不必跨进程, host main 进程内读完 → 内存 buffer 经 IPC 传给 VMHost? **不行** — 大文件 IPC stream 不合适. 改为 main 进程把 srcURL 路径传 IPC, VMHost 子进程**直接 open(2)** (因为 sandboxless, 文件系统权限只看 user perms) | **P0** — 必须 sandboxless 才走得通; 验证 VMHost 是否直接 open 任意 host path |
| R6 | 大文件 (> 1 GiB) 中途 socket 卡死 | 1.5 GiB 测试. timeoutSec 默认 600, 超时返 timeout 错误 + 删 .hvm-tmp | P2 |
| R7 | guest-file-write 返 count < 期望 (短写) | QGA 协议规定 count 是实际写入; 我们循环写满, 跟 send(2) 同思路 | 已论证 |
| **R8** | qemu-ga 服务挂掉 (升级 / crash) | qga socket fileExists 但 connect 后 read 立即 EOF — `QgaError.readFailed("EOF before newline")`. 错误信息升级为 "qemu-ga 服务未响应, 请 guest 内重启 qemu-ga service" | P1 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-A** | `HVMQemu/QgaSocket.swift` (抽 connectUnix/send/read 共用), `QgaFile.swift` (open/write/read/close + push/pull). | 1.0 天 | **代码合入** (2026-05-06) — 协议层 + push/pull 编排; 真机 smoke 推到 PR-C 阶段 |
| **PR-B** | `HVMIPC/Protocol.swift` 加 `dbgFilePush` / `dbgFilePull` op + payload; `QemuHostEntry.swift` 加 `handleDbgFilePush` / `handleDbgFilePull` (复用 PR-A `QgaFile`) | 0.5 天 | **代码合入** (2026-05-06) |
| **PR-C** | `app/Sources/hvm-dbg/Commands/FileCommand.swift` (push/pull 子命令); `HvmDbg.swift` 注册. | 0.5 天 | **代码合入** (2026-05-06) — `hvm-dbg file push/pull --help` 已可用; 端到端 sha256 比对待真机 |
| **PR-D** | GUI: `DetailBars.sharingSection` 加 [传文件到 VM…] / [从 VM 取文件…] 按钮; `FileTransferDialog.swift` (HVMModal: form / running / done); IPC client 走 main 进程 Task.detached; `.hvmProbe` ID 注册 (`detail.sharing.button.{push,pull}File` / `dialog.fileTransfer.{input.remotePath,button.{start,cancel,close}}`) | 1.0 天 | **代码合入** (2026-05-06) — make build + make install 通过 |
| **PR-E** | docs: 回写 v1/QEMU_INTEGRATION.md / v1/GUI.md / v1/CLI.md / v1/DEBUG_PROBE.md; CLAUDE.md "调试/诊断" 与 "GUI 约束" 节加 hvm-dbg file push/pull 一行; v3/README.md 状态同步 | 0.2 天 | **进行中** |

合计 ~3.2 天 / 1 人. **PR-A → PR-B → PR-C 串行**, PR-D 依赖 PR-B + PR-C, PR-E 收尾.

P0 Gates (PR-A 期内必须验):
- R1 (qemu-ga 是否开放 guest-file-*)
- R5 (VMHost 子进程直 open 用户文件可行)

任一 P0 不过 → 推回 v3 设计稿, 不进 PR-B.

## 未决事项 (Decisions)

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| D1 | hvm-cli 暴露 `file push/pull`? | **不暴露**. 用户走 GUI; 高级 / 脚本场景走 hvm-dbg. hvm-cli 限"管理 VM bundle" 语义, 运行时 IPC 操作向 hvm-dbg 收敛 | 已决 (本稿) |
| D2 | 文件夹递归 | **v1 不做**. 用户 `zip` 后 push, guest 内 unzip. 真要做 v2 在 host 端 walk + 多文件并发 push (chunk-level 不变) | v2 提案 |
| D3 | VZ 后端文件传输 | **单独提案 `VZ_FILE_SHARE.md`**. 走 `VZSharedDirectory` + virtiofs (Apple-native, macOS 13+ guest 自带 driver). 不在本稿 | 后续 |
| D4 | 进度反馈精度 | **v1 client 端时间预估 + chunk-level 字节计数**, 不走 IPC stream. v2 加 IPC stream 真实时进度 | 已决 |
| D5 | 取消传输 | **v1 GUI cancel 按钮仅 close modal**, 后台 chunk 循环跑完才退出 (留 .hvm-tmp 残留). 复杂中断协议 v2 再加 | 已决 |
| D6 | 大小上限 | **硬上限 4 GiB** (单文件; 超出拒绝). **软警告 100 MiB** (传输慢, 用户自决). 4 GiB 之外用户先 split | 已决 |
| D7 | 远端路径已存在 | **覆盖** (rename .hvm-tmp 替换). v1 不加 `--no-clobber`; v2 加 | 已决 |
| D8 | 超时默认 | **600 秒** (10 分钟). 4 GiB / 1 MB/s 最坏需要 70 分钟, 用户必须显式 `--timeout` 拉长. 默认 600 覆盖 < 600 MiB 文件 | 已决 |
| D9 | sha256 校验 | **--verify** 可选 flag, 默认不算 (省时间). 加上时 host 算本地 sha256 + guest 内走 `guest-exec` 跑 `certutil -hashfile sha256` (Win) / `sha256sum` (Linux) 比对 | 已决 |
| D10 | 加密 VM 启动期文件传输 | 同明文 — QGA 通路与磁盘加密无关. **GUI 按钮唯一区别**: 加密 VM 必须先解锁启动后才能用 (UI 已有 disabled 态) | 已决 |

## 设计变更日志

### 2026-05-05 v1 — 本稿

初稿. 关键决策:

- 选方案 A (QGA `guest-file-*`); B (virtiofs) 推后单独提案
- v1 仅 `hvm-dbg file push/pull` + GUI Sharing 区两按钮; hvm-cli 不暴露 (D1)
- chunk 1 MiB, 默认 timeout 600s, 软警告 100 MiB, 硬上限 4 GiB
- VZ 后端不在本稿 (走 `VZSharedDirectory` + virtiofs, 单独提案)
- P0 gates: R1 (qemu-ga 是否开放 file API) + R5 (VMHost 子进程直读用户文件)

## 相关文档

- 现有 QGA exec 通路: [HVMQemu/QgaExec.swift](../../app/Sources/HVMQemu/QgaExec.swift)
- QGA 协议: <https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html>
- IPC 协议: [HVMIPC/Protocol.swift](../../app/Sources/HVMIPC/Protocol.swift)
- 现有 GUI Sharing 区 (待加按钮): [DetailBars.swift:457](../../app/Sources/HVM/UI/Content/DetailBars.swift)
- UTM Guest Tools 装包来源 (qemu-ga.exe): [HVMQemu/UtmGuestToolsCache.swift](../../app/Sources/HVMQemu/UtmGuestToolsCache.swift)
