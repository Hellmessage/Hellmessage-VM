# 调试探针: hvm-dbg + HDP-GUI 自动化协议

本文档描述 HVM 的两套调试/自动化能力的**当前代码现状**:

1. **hvm-dbg** — 命令行调试探针. 给 AI agent / 脚本一个稳定入口去操作运行中的 guest
   (键盘 / 鼠标 / 截屏 / OCR / 跑命令 / 传文件) 与控制台.
2. **HDP-GUI 协议** — `hvm-dbg gui` 子命令族 + HVM 主进程内的 `HVMGuiProbe` server, 用来
   自动化测试 **HVM 自己的 SwiftUI GUI** (按钮 / 输入框 / dialog).

源码:
- `app/Sources/hvm-dbg/HvmDbg.swift` — `@main` 入口, 注册全部子命令
- `app/Sources/hvm-dbg/Commands/*.swift` — 各子命令实现
- `app/Sources/hvm-dbg/Support/*.swift` — `IPCCall` / `BundleResolve` / `OutputFormat` 公共件
- `app/Sources/HVMGuiProbe/*.swift` — HDP-GUI server 端 (`ProbeServer` / `ProbeRegistry` /
  `ViewRegistry` / `ScreenshotRenderer` / `HVMProbeViewModifier`)

> 项目仅 QEMU 单后端, guest 仅 Linux / Windows (arm64). 个别源文件注释里仍有 "VZ" / "VZUSBKeyboard"
> 等历史措辞, 实际通路均走 QEMU host 子进程 + IPC, 本文以 QEMU-only 现状为准.

---

## 1. hvm-dbg 定位

`hvm-dbg` 是 **AI agent / 自动化脚本操作 guest 的唯一入口**, 取代脆弱的 osascript / AppleScript
UI scripting (依赖屏幕坐标 + 辅助功能权限, 不可复现). 项目约束明确**禁止**用 osascript 模拟 GUI 点击.

设计原则:

- **零新协议**: hvm-dbg 不自己实现任何 guest 通信协议. 它只复用 HVM 主进程已暴露的
  QMP / QGA (qemu-guest-agent) / HDP (IOSurface 显示) / SPICE vdagent / HDP-GUI 的封装,
  通过 IPC 把请求转给 host 子进程执行.
- **遇到能力缺失立即扩展 hvm-dbg, 不绕路**: 不退回 osascript, 不让用户手动 powershell /
  inline shell hack. 新子命令 = 新建 `Commands/XxxCommand.swift` + 注册到 `HvmDbg.swift` +
  配套 host 端 `IPCOp` + handler.

### 1.1 通用机制

绝大多数子命令走同一套 IPC 模式 (`Support/IPCCall.swift`):

1. `BundleResolve.resolve(<vm>)` 把 VM 名称或 `.hvmz` 路径解析成 bundle URL
   (`BundleDiscovery`, 默认根 `~/Library/Application Support/HVM/VMs/`).
2. `IPCCall.socketPath(forVM:)` 检查 `BundleLock` — VM 未运行 (`busy=false` 或无
   `socketPath`) 直接抛 `ipc.socket_not_found`; 运行中则从锁记录拿 host 子进程的 IPC
   unix socket 路径.
3. `IPCCall.send(socketPath:op:args:timeoutSec:)` 走 `SocketClient.request` 发一个
   `IPCRequest`, 拿 `IPCResponse`. `ok=false` 抛 `HVMError.ipc(.remoteError(...))`.
4. 子命令把 response 里的 `payload` JSON 解码成对应 `IPCDbg*Payload` 结构, 按 `--format`
   渲染.

例外: `qemu-launch` 不走运行中 VM 的 IPC (它**自己**在前台 in-process 拉起 QEMU);
`webdav-test` 纯离线; `webdav-serve` 自己起 server; `gui *` 走另一条 HDP-GUI socket.

### 1.2 输出格式与退出码

所有子命令支持 `--format human | json` (`Support/OutputFormat.swift`). 各命令默认值不同
(agent 友好的命令默认 `json`, 人读的默认 `human`, 见各节).

退出码映射 (`exitCode(for:)`), 与 hvm-cli 对齐 + hvm-dbg 专属 20–23:

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用失败 |
| 2 | `config.*` 参数错误 |
| 3 | `bundle.not_found` |
| 4 | `bundle.busy` |
| 6 | `ipc.timed_out` (含 `wait` 超时) |
| 10 | `backend.*` |
| 20 | `dbg.vm_not_running` |
| 21 | `ipc.socket_not_found` / `connection_refused` |
| 22 | `dbg.console_agent_offline` |
| 23 | `dbg.no_match` (`find-text` 没找到) |

其它命令各自的专属码: `exec` 透传 guest exit code (上限 255), 7 = sentinel 解析失败;
`paste-files` 2 = 有 failed 项; `qemu-launch` 2/3/5/30–32 见该节.

---

## 2. 子命令清单

`HvmDbg.swift` 注册 19 个顶层子命令 (其中 `gui` 自身再带 11 个 sub-subcommand,
`file` / `dir` 各带 subcommand). 逐个如下.

### 2.1 screenshot — 抓 framebuffer 输出 PNG

抓 guest 当前 framebuffer, 输出 PNG. VM 必须在跑 (state=running / paused).

```
hvm-dbg screenshot <vm> [--output X.png] [--format human|json]
```

- `--output`: 文件路径; 不给则把 PNG 二进制流写 stdout (human 模式).
- `--format json`: 输出 `{ pngBase64, widthPx, heightPx, sha256 }`, 不写文件.
- 默认 `--format human`.

```
hvm-dbg screenshot Win --output /tmp/shot.png
hvm-dbg screenshot Win > /tmp/shot.png
```

### 2.2 status — guest 视角运行信息

偏 guest 视角的运行信息 (区别于 `hvm-cli status` 的 host 视角), 给 agent 判断 "画面变了没 /
VM 还在跑没".

```
hvm-dbg status <vm> [--format human|json]
```

输出: `state` / `guestResolution {widthPx, heightPx}` / `lastFrameSha256` /
`consoleAgentOnline`. 默认 `--format json`.

> 注: `status` 的 `guestResolution` 是 `defaultFramebufferSize` 估算值, **不**反映 guest 真实
> 当前分辨率. 要真实尺寸用 `display-info`.

### 2.3 key — 注入键盘事件

注入键盘事件到 guest. 走 host 侧键盘注入, 不依赖辅助功能权限. `--text` / `--press` 互斥.

```
hvm-dbg key <vm> --text "uname -a\n"
hvm-dbg key <vm> --press "cmd+t Return shift+a"
```

- `--text`: 逐字符敲入 (US ASCII printable + `\n` `\t`).
- `--press`: 组合键序列, 空格分隔多组: `cmd+t` / `Return` / `shift+a cmd+s`.
- 默认 `--format human`.

### 2.4 mouse — 鼠标事件

注入鼠标事件. 坐标系: guest 像素左上原点, 接受 `"x,y"` 整数格式 (非整数会被 host 端拒).

```
hvm-dbg mouse <vm> move         --to 640,360
hvm-dbg mouse <vm> click        --at 640,360 --button right
hvm-dbg mouse <vm> double-click --at 100,200
hvm-dbg mouse <vm> drag         --from 50,50 --to 500,500
```

- 操作 (位置参数): `move` / `click` / `double-click` / `drag`.
- `--to` (move/drag 终点) / `--at` (click/double-click) / `--from` (drag 起点).
- `--button left|right|middle` (默认 left).
- 默认 `--format human`.

### 2.5 ocr — 抓屏 + 文字识别

抓 framebuffer + Vision framework OCR, 全屏或裁剪 region.

```
hvm-dbg ocr <vm> [--region "x,y,width,height"] [--format human|json]
```

- `--region`: 裁剪区域 (guest 像素左上原点); 不给 = 全屏.
- json 输出每个文本块 `{ bbox: [x1,y1,x2,y2], text, confidence }`. 默认 `--format json`.

> 端到端验证时 OCR 在 Win 控制台 / 中文 IME / 倾斜窗口下误识率高 (如 `pnputil`→`prputil`).
> 验证命令是否真执行**优先用 `exec-guest`** (拿 stdout); 验证显示状态优先 `screenshot` 自己肉眼看.

### 2.6 find-text — 抓屏 + OCR + 子串匹配

抓屏 + OCR + 子串匹配 (大小写不敏感). 找到返回 bbox + center; 找不到退出码 23.

```
hvm-dbg find-text <vm> "Sign In" [--format human|json]
```

json 输出 `{ match, bbox, center: [x,y], text, confidence }`. 默认 `--format json`. 与
`mouse click --at` 配合可在不知坐标时点按钮:

```
center=$(hvm-dbg find-text foo "Sign In" | jq -r '.center | "\(.[0]),\(.[1])"')
hvm-dbg mouse foo click --at "$center"
```

### 2.7 wait — 轮询等 guest 进入某状态

客户端实现, 复用 `dbgStatus` / `dbgFindText` / `dbgScreenshot` IPC 轮询. 达成退出 0, 超时退出 6.

```
hvm-dbg wait <vm> --for text         --match "login:"
hvm-dbg wait <vm> --for state        --eq running
hvm-dbg wait <vm> --for frame-stable --within 2
```

- `--for text`: OCR 找 `--match` 子串, 命中即返回.
- `--for state`: `status` 的 `state` 字段 == `--eq` (running / stopped / paused / …).
- `--for frame-stable`: 连续 `--within` 秒 (默认 2) screenshot sha256 不变.
- `--timeout` 总超时 (默认 60) / `--interval` 轮询间隔 (默认 1.0) / 默认 `--format json`.

### 2.8 boot-progress — 启发式判断启动阶段

启发式判断 guest 启动阶段, 给 agent 粗分支决策.

```
hvm-dbg boot-progress <vm> [--format human|json]
```

输出 `{ phase, confidence, elapsedSec }`. phase 取值: `bios` / `boot-logo` /
`ready-tty` / `ready-gui` / `unknown`. 默认 `--format json`.

### 2.9 console — 读/写 guest virtio-console (hvc0)

读/写 guest 的 virtio-console (hvc0), 走 host 侧 ring buffer + tee 日志. 不做流式 attach.

```
hvm-dbg console <vm> --read [--since-bytes N]
hvm-dbg console <vm> --write "ls -la\n"
echo -n "payload" | hvm-dbg console <vm> --write-stdin
```

- `--read`: 拉 `[since-bytes, totalBytes)` 的 guest stdout (base64 解码后输出原始字节).
  默认 `--since-bytes 0` = 拿 ring buffer 全量; 客户端用响应里的 `totalBytes` 当下次起点.
- `--write "<text>"`: 把 text 当 UTF-8 写入 guest stdin (不自动加 `\n`).
- `--write-stdin`: 从 host stdin 读字节流写入. 默认 `--format json`.

### 2.10 exec — console 自动登录 + 跑命令

通过 console 自动登录 + 跑命令 + 拿输出. **完全客户端实现**: 状态机在 hvm-dbg 跑, 服务端只
暴露 `console.read` / `console.write` 两个原子 op. 需 guest 内 hvc0 起了 getty.

```
hvm-dbg exec <vm> --user root --password-from-stdin -- /bin/sh -c "uname -r"
hvm-dbg exec <vm> -- whoami     # 省略 --user, 假定已是 logged-in shell
```

- `--user`: 登录用户名 (省略则假定已登录).
- `--password` / `--password-from-stdin`: 密码 (推荐 stdin, 避免命令行 history 泄露;
  密码不打日志不进 stdout/stderr).
- `--via console` (目前仅 console) / `--timeout` (默认 60) / 默认 `--format json`.
- 命令在 `--` 后给.

流程: 拿 console watermark → 触发 prompt → 匹配 `login:` / `Password:` / shell prompt
自动登录 → 用 uuid sentinel (`__HVM_BEGIN_*__` / `__HVM_END_*__:$?`) 包裹命令 → 提取
BEGIN..END 之间字节为 stdout + 抓 exit code.

退出码: 透传 guest exit code (上限 255); 6 = 超时; 7 = sentinel 解析失败 (console buffer
被截断 / 命令未完整执行).

### 2.11 exec-guest — 通过 qemu-guest-agent 跑命令

通过 qemu-guest-agent (QGA) 在 guest 内跑命令拿 stdout/stderr/exit_code. **绕过 keyboard
typing (避 IME 字符替换) / OCR (避识别误差) / GUI mouse** — 端到端自动化验证 guest 行为最可靠通路.

```
hvm-dbg exec-guest <vm> --path cmd.exe --args /c --args 'echo hello'
hvm-dbg exec-guest <vm> --ps  'Get-Date'
hvm-dbg exec-guest <vm> --cmd 'echo %USERNAME%'
```

- `--path` + `--args` (重复使用传多个 argv; 以 `-` 开头需 `--args=-Foo` 格式).
- `--ps "<line>"`: 自动包成 `powershell.exe -NoProfile -EncodedCommand <utf16le-base64>`,
  绕开 shell quote / IME.
- `--cmd "<line>"`: 自动包成 `cmd.exe /C <line>`.
- `--timeout-sec` (默认 30; IPC 读超时自动 +5s) / 默认 `--format human` (自动 base64 解码
  stdout/stderr).

配套: guest 内 qemu-ga 服务在跑 (UTM Guest Tools 装包含); argv 挂 qga chardev +
`org.qemu.guest_agent.0` virtserialport (QemuHostEntry 自动 wire). 非 0 exit 透传退出码
(timeout 映射 124).

### 2.12 file — host ↔ guest 单文件传输 (QGA)

走 qemu-guest-agent `guest-file-*` API, 单文件不递归 (用户先 zip). 软警告 100 MiB / 硬上限
4 GiB. 速率约 1–10 MB/s.

```
hvm-dbg file push <vm> --src /local/x.iso --dst 'C:\Windows\Temp\x.iso'
hvm-dbg file pull <vm> --src 'C:\path\file.log' --dst /local/path.log
```

- `push`: host → guest (覆盖目标, 中断留半成品).
- `pull`: guest → host (本地走 `.hvm-tmp` + atomic rename).
- 共有 `--src` / `--dst` / `--timeout-sec` (默认 600) / 默认 `--format human` (打吞吐).

### 2.13 paste-files — 模拟 Cmd+V 文件粘贴 (vdagent)

模拟用户在 framebuffer view 按 Cmd+V 的整条 host→guest 文件粘贴通路. 走 SPICE vdagent
`VD_AGENT_FILE_XFER_*`, 落 **guest `~/Downloads`**, 约 50 MB/s. 绕过 NSPasteboard 拦截
(server 端走相同 `clipboard.paste-files` IPC).

```
hvm-dbg paste-files <vm> --file /local/a.txt --file /local/b.zip
```

- `--file`: host 文件路径, 可指定多次.
- `--timeout-sec` (默认 1800) / 默认 `--format human`.
- 输出 successful / skipped (文件夹 / >4 GiB 等被 server 跳过) / failed 三类. 有 failed 退出码 2.

> 与 `file push` 区别: `file push` 走 QGA 落任意路径 (脚本场景); `paste-files` 走 vdagent
> 落 `~/Downloads` (验证 GUI Cmd+V 后端通路). 详见设计稿 `docs/v3/HOST_FILE_PASTE.md`.

### 2.14 dir ls — 列 guest 内目录 (QGA)

走 qemu-guest-agent 列 guest 内某个目录 (一层不递归). GUI "从 VM 取文件" 浏览器同款后端的
CLI 入口.

```
hvm-dbg dir ls <vm> --path 'C:\Users'    # Windows guest
hvm-dbg dir ls <vm> --path /home         # Linux guest
```

- `--path`: guest 内绝对路径 / `--timeout-sec` (默认 30) / 默认 `--format human` (对齐表).
- json 走 `IPCDbgListDirPayload`: 每项 `{ name, fullPath, isDir, size }`.

### 2.15 display-info — guest 真实 framebuffer 尺寸

通过 QMP `screendump` 读 PPM header, 拿 guest **当前真实** framebuffer 尺寸 (跟 `status` 的
估算值不同). 用于验证 spice-vdagent dynamic resize 是否真生效.

```
hvm-dbg display-info <vm> [--format human|json]
```

输出 `{ widthPx, heightPx }`. 默认 `--format human` (`WxH`).

### 2.16 display-resize — 触发 host → guest 动态 resize

模拟 GUI 拖窗口触发 resize, 走两条通路: HDP `RESIZE_REQUEST` (Linux virtio-gpu) +
vdagent `MONITORS_CONFIG` (Win spice-vdagent → SetDisplayConfig).

```
hvm-dbg display-resize <vm> --width 1280 --height 720 [--format human|json]
```

- `--width` (640..7680) / `--height` (480..4320), 越界退出码 1.
- 输出 `{ widthPx, heightPx, hdpResult, vdagentResult }`. 默认 `--format human`.

> 测试规约: 调此命令时 GUI 不能同时 attach 该 VM (iosurface / vdagent chardev 都是
> single-client). 配合 `display-info` 前后对比 framebuffer 尺寸验证生效:
> `display-info` → `display-resize` → `sleep` → `display-info`.

### 2.17 qemu-launch — 直接拉起 QEMU 后端 VM

独立调试命令: 直接 in-process 前台拉起包内 `qemu-system-aarch64`, **绕过 hvm-cli start 的
host 进程 / IPC server 流程**, 用于验证 QEMU 模块端到端正确性. 不抢 BundleLock.

```
hvm-dbg qemu-launch <vm>            # 启动并前台附着 (ctrl+c → ACPI powerdown)
hvm-dbg qemu-launch <vm> --dry-run  # 仅打印 argv 不真启
```

- `--dry-run`: 仅打印 qemu binary + argv 后退出.
- `--shutdown-timeout` (默认 10): ctrl+c 发 `system_powerdown` 后等待秒数, 超时强杀.
- 要求 `engine == qemu` (否则退出 2). 自动处理 swtpm sidecar (Win + tpm) / virtio-win 缓存
  (Win) / QMP 连接重试. 退出码 2 (非 qemu) / 3 (找不到 QEMU 包) / 5 (QMP 连接失败) /
  30–32 (swtpm 相关).

> 后端启停 e2e 优先走 `hvm-cli` 或 `make run-app` (脱离 shell 会话, 防孙子 QEMU 进程随会话被
> 杀误判失败). `qemu-launch` 适合验单次 argv / QMP 通路.

### 2.18 webdav-test — 离线测 SPICE WebDAV 协议层

离线跑 SPICE WebDAV mux frame codec + HTTP 解析 + WebDAV 动词分发, **不接 socket**.
覆盖 ~44 个 case (mux frame round-trip / 半帧 / pipeline / HTTP OPTIONS·PUT·partial /
WebDAV OPTIONS·PROPFIND·GET·PUT·MKCOL·DELETE·MOVE / 路径 escape 拒 / 响应序列化).

```
hvm-dbg webdav-test
```

无参数. 打印逐 case ✔/✗ + 总计; 有失败退出码 1. 用临时目录, 不依赖运行中 VM.

### 2.19 webdav-serve — 独立跑 SpiceWebdavServer

独立跑 `SpiceWebdavServer` 做端到端测 (QEMU 起来后, 或本机协议测). 默认作 client 连入一个
已存在的 socket; `--listen` 则作 server 监听 (给 curl / socat / Python client 手动测).

```
hvm-dbg webdav-serve --socket <path> --root code=/Users/me/code:rw [--listen]
```

- `--socket`: QEMU chardev unix socket 路径.
- `--root name=path[:ro|:rw]`: 共享根, 可多个 (默认 ro).
- `--listen`: HVM 作 server 监听 (默认是 client 连入). 跑到 Ctrl-C 退出.

---

## 3. guest 内操作小结

| 需求 | 命令 | 通路 |
|---|---|---|
| 跑命令拿 stdout (最可靠) | `exec-guest` | qemu-guest-agent |
| 跑命令 (无 QGA, 走串口登录) | `exec` | virtio-console (hvc0) + getty |
| 看控制台原始字节 | `console --read` | host ring buffer |
| 看画面 | `screenshot` | HDP framebuffer |
| 找/识别画面文字 | `ocr` / `find-text` | Vision OCR |
| 键盘 / 鼠标 | `key` / `mouse` | host 注入 |
| 等某状态 | `wait` | 轮询 status/OCR/frame |
| 真实分辨率 / resize | `display-info` / `display-resize` | QMP / vdagent |

`exec` (串口登录) vs `exec-guest` (QGA): 优先 `exec-guest` — 不受 IME 字符替换 / OCR 误差影响,
拿原始 stdout/stderr/exit_code. `exec` 是没有 QGA 时的兜底, 自己跑登录状态机.

---

## 4. 文件传输小结

| 命令 | 通路 | 落点 | 速率 | 场景 |
|---|---|---|---|---|
| `file push/pull` | QGA `guest-file-*` | guest 任意路径 | 1–10 MB/s | 脚本 / 自动化 |
| `paste-files` | SPICE vdagent `file_xfer` | guest `~/Downloads` | ~50 MB/s | 验 GUI Cmd+V 后端 |

`file` 双向 (push host→guest / pull guest→host), 软警告 100 MiB / 硬上限 4 GiB.
`paste-files` 模拟 Cmd+V 整条通路但绕过 NSPasteboard 拦截 (走相同 `clipboard.paste-files`
server IPC); 文件夹 / 超大文件会被 server 跳过返 skipped.

---

## 5. HDP-GUI 协议 (hvm-dbg gui)

测试 **HVM 主进程 GUI 自身行为** (创建向导 / 加密 dialog / 详情页 / 按钮 / 输入框) 走 HDP-GUI
协议. 设计稿 `docs/v3/HVM_DBG_GUI_PROTOCOL.md`.

### 5.1 启用 server + socket

- **启用**: `HVM_GUI_PROBE=1 open build/HVM.app` (或 `/Applications/HVM.app`). release build
  默认**不**启 server (不暴露 socket).
- **socket 路径**: `~/Library/Application Support/HVM/run/hvm-dbg-gui.sock`
  (`ProbeServer.defaultSocketPath`, 与 `GuiSocket.path` 对齐). server 没启时 hvm-dbg 给清晰
  指引 "HVM 主进程未以 HVM_GUI_PROBE=1 启动".

server 端 (`HVMGuiProbe/ProbeServer.swift`): 跑在 HVM 主进程内, 用 `SocketServer` 包装监听该
socket; handler 在 IPC 池线程收到请求后 hop 到 `@MainActor` 跑实际逻辑 (操作 NSWindow /
SwiftUI state 必须主线程).

### 5.2 gui 子命令

```
hvm-dbg gui ping                                  # 验 server 已启
hvm-dbg gui list [--prefix dialog.createVM.] [--format human|json]
hvm-dbg gui click  --identifier <id>             # 触发 button.action / 切 toggle
hvm-dbg gui type   --identifier <id> --text "…"  # 给 textField 输文字 (覆盖现值)
hvm-dbg gui read   --identifier <id>             # 读 textField/toggle 当前值
hvm-dbg gui screenshot [--output X.png]          # 截主窗口 + dialog → PNG
```

- `gui ping` → server 返 `pong` + version.
- `gui list` → 列 `ProbeRegistry` 已注册控件 `{ identifier, label, role }`; `--prefix` 过滤.
- `gui click` → button 调 action closure; toggle 翻转值. 错 id / 类型不匹配返
  `gui.identifier_not_found`.
- `gui type` → textField setter; `gui read` → textField getter 或 toggle ("true"/"false").
- `gui screenshot` → `ScreenshotRenderer.captureMainWindow()`, 见 5.5.

额外 debug-only 子命令 (仅测试用, 验 dialog / 拖放通路):

```
hvm-dbg gui trigger-error [--title --message --details --hint]   # push 测试 ErrorDialog
hvm-dbg gui dismiss-error                                         # dismiss 当前 ErrorDialog
hvm-dbg gui show-window                                           # accessory 模式拉出主窗口
hvm-dbg gui simulate-drop --file a --file b                       # 直戳 onFilePaste 闭包
hvm-dbg gui show-drop-overlay [--hide] [--count N]               # 切 dropOverlay 显隐
```

这些走 `ProbeServer` 注入的 `ProbeErrorPresenter` 适配器 (HVMApp 启动时注入) / 直接 BFS 找
可见 `FramebufferHostView` 戳其 `onFilePaste` / `probeShowDropOverlay`.

### 5.3 业务侧接入 .hvmProbe(id:)

SwiftUI 控件用 `.hvmProbe(id:label:action:)` modifier 注册到 `ProbeRegistry`
(`HVMProbeViewModifier.swift`):

```swift
Button("Create") { doCreate() }
    .hvmProbe(id: "dialog.createVM.button.create",
              label: "Create",
              action: .button { doCreate() })
```

`ProbeAction` 三型 (`ProbeRegistry.swift`):

- `.button(@MainActor () -> Void)` — click 触发.
- `.textField(getter:setter:)` — type 调 setter, read/list 显示走 getter.
- `.toggle(getter:setter:)` — click 翻转, read 返 true/false.

> action closure 必须跟原 onTap 等价 (业务侧重写一次): SwiftUI `Button.action` 是 internal,
> 无法反射提取.

modifier `onAppear` 注册 / `onDisappear` 移除. `ViewRegistry` 把 `gui.list/click/type/read`
请求映射到 `ProbeRegistry` 的 closure.

新 GUI (`app/Sources/HVM/GUI/**`, `GUI=new`) 走 `HVMUI.*` 组件, 交互组件的 `probeID: String`
**必传** (编译期 enforce). 命名规范 `<scene>.<role>.<element>`, 例
`dialog.encrypt.field.password` / `toolbar.button.create` / `vmlist.row.item-<vmID>`.
复合控件 (Select / Dialog / Wizard) 的子控件 probe id 由组件内部自动派生 (`.trigger` /
`.close` / `.confirm` / `.cancel` 等), 业务侧只传 base. 详见 `docs/v4/NEW_GUI.md` "R6" 节 +
`docs/v3/HVM_DBG_GUI_PROTOCOL.md`.

### 5.4 为什么走自家 closure registry, 不走 a11y

(`ProbeRegistry.swift` 注释) SwiftUI 通过 `NSHostingView` 合成 a11y children, 但默认只在
VoiceOver 激活时暴露完整 tree. 程序内 `accessibilityChildren()` 查询拿不到 Button /
TextField 等叶子控件 (实测 macOS 14+), 强用 `AXUIElement` 需要 a11y trust. 改走自家 closure
registry 更直接: `hvm-dbg gui click <id>` 直接调闭包 (= 等价用户点击 action), 不依赖系统 a11y
服务, 跨 SwiftUI / AppKit 一致.

缺点: 不能模拟原生 mouse event 链 (例如 hover 后才出现的菜单). 当前场景都是直接
button.action / textField.text, 这套足够.

### 5.5 截图 (gui screenshot)

`ScreenshotRenderer.captureMainWindow()` 截 keyWindow / mainWindow (含弹层 dialog):

1. `NSView.bitmapImageRepForCachingDisplay` + `cacheDisplay` 渲染主 contentView (SwiftUI
   普通绘制), **不**用 `CGWindowListCreateImage` (避免 screen recording 权限).
2. `bitmapImageRepForCachingDisplay` **抓不到 Metal-backed view** (`FramebufferHostView` 在
   主截图里是黑块). 遍历 subview tree 找所有 `FramebufferHostView`, 调
   `renderer.snapshotCGImage()` 拿 BGRA framebuffer, 用 `CGContext` 等比 letterbox 合成到对应
   rect 上, 再 PNG encode.

让截图跟用户实际看到的一致 (含 SwiftUI chrome + 嵌入的 guest 画面).

### 5.6 GUI 测试优先级

任何 GUI 改动 (新 dialog / 新按钮) **优先**用 `hvm-dbg gui` 自动化测, 不让用户手动点. 典型流程:

```
HVM_GUI_PROBE=1 open build/HVM.app
hvm-dbg gui ping
hvm-dbg gui list --prefix dialog.createVM.
hvm-dbg gui type  --identifier dialog.createVM.field.name --text "test-vm"
hvm-dbg gui click --identifier dialog.createVM.button.create
hvm-dbg gui screenshot --output /tmp/after.png
```

---

## 6. WebDAV 协议调试

共享目录走 SPICE WebDAV over virtio-serial. 协议层 / 端到端调试:

- `hvm-dbg webdav-test` — ~44 case 离线单测 (mux frame / HTTP / WebDAV 动词 / 路径 escape).
  CI 友好, 不依赖 VM.
- `hvm-dbg webdav-serve --listen` — 起 server 监听本地 socket, 给 curl / socat / Python
  client 手动测协议交互.

详见 `docs/v1/SHARING.md` + 设计稿 `docs/v3/SHARED_FOLDER.md`.

---

## 7. 调试工作方式约束 (摘自 CLAUDE.md)

- **禁止 osascript / AppleScript UI scripting 模拟 GUI 点击** (脆弱, 依赖坐标 + 辅助功能权限).
- 启停 VM 走 `hvm-cli` / `hvm-dbg`, 不靠 HVM GUI.
- guest 内任何操作 (看桌面 / 点按钮 / 键入 / 跑命令) 走 `hvm-dbg` 子命令.
- **hvm-dbg 缺功能时扩展子命令, 不绕路**: 不硬编码 unattend / 不让用户 powershell / inline
  shell hack. 加完命令立即用它跑测试.
- **端到端验证用 hvm-dbg, 不依赖 OCR 文本判断成败**: 验命令是否执行优先 `exec-guest` (拿
  stdout); 验显示状态优先 `screenshot` + 自己肉眼看 (Read PNG). OCR 在 Win 控制台 / 中文 IME
  误识率高.
- **自主调试不让用户操作 GUI**: VM 需 restart 自己 stop+start; 自动化卡死 (协议层不通) 才告诉
  用户单一 minimal action.
