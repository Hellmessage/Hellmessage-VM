# 调试探针 (`hvm-dbg`)

## 目标

- 提供**程序化**方式在 guest 内做操作(看桌面、敲键盘、动鼠标、点按钮、抓日志)
- **替代** CLAUDE.md 明确禁止的 `osascript` / AppleScript UI scripting 方案
- 不引入新协议, 只封装 VZ 已暴露的公开 API
- 供 AI agent / 自动化脚本 / 人工调试混合使用

## 为什么不用 osascript

CLAUDE.md 约束:

> **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(脆弱、依赖屏幕坐标和辅助功能权限, 不可复现)

osascript 的致命问题:

1. 依赖辅助功能权限 → 每次需要用户点允许
2. 依赖 guest 窗口绝对坐标 → 分辨率改了就失效
3. 只能操作 host 的 GUI, **不能**跨进入 guest
4. 脚本与 UI 结构耦合 → AppKit 版本升级就崩
5. 不能脱离 UI(无头模式下毫无意义)

`hvm-dbg` 的替代方案 — **直接走 VZ 的输入设备 API**:

| 需求 | osascript 方式 | hvm-dbg 方式 |
|---|---|---|
| 敲键 | `tell application "System Events" to keystroke "ls\r"` | `hvm-dbg key foo --text "ls\n"` → VZUSBKeyboard 事件 |
| 点击 | `click at {300, 400}` | `hvm-dbg mouse foo click --at 300,400` → VZUSBScreenCoordinatePointingDevice 事件 |
| 抓屏 | `screencapture` 全屏, 还要算位置 | `hvm-dbg screenshot foo` → 直接拿 VZ frame buffer |
| 看文本 | 抓屏 + OCR | 抓屏 + 可选 Vision framework OCR |

## 定位

- `hvm-cli`: 管**外部**资源 — 启动/停止 VM, 改 config, 管磁盘 (host 视角)
- `hvm-dbg`: 管**内部**交互 — 截屏、键盘/鼠标注入、读 console 输出 (guest 视角)
- 两者无重叠, 互不调用彼此功能

## 工作原理

`hvm-dbg` 作为**客户端**连到运行中的 `HVMHost` 进程的 IPC socket, 让 VMHost 代执行 VZ 操作(因为 VZ API 必须在持有 `VZVirtualMachine` 的进程里调, 不能跨进程直接调)。

```
hvm-dbg ──IPC──▶ HVMHost ──VZ API──▶ VM
         Unix     (持有 VZVirtualMachine)
         socket
```

Socket 路径: `<bundle>/.lock` 里记录的 `socketPath`, 默认 `~/Library/Application Support/HVM/run/<uuid>.sock`。

## 扩展原则(必须遵守)

1. **零新协议**: 只包装 VZ 公开 API, 不实现私有 guest agent 协议 (例外: 未来若加官方的 guest agent 扩展, 走另一章节讨论)
2. **无副作用命令先行**: 截屏/读 console 先实现, 注入键鼠后加
3. **子命令能干什么完全由 VZ 能不能干决定**, 不临时加"曲线救国"(例: VZ 不支持枚举 guest 进程, `hvm-dbg` 就没这命令, 要看进程用 exec 跑 `ps`)
4. **命令粒度对 AI 友好**: 尽量原子操作, 输出 JSON 方便 LLM 解析
5. **输出稳定**: 字段名不随版本改, 新增字段向后兼容

## 子命令总览

```
hvm-dbg screenshot <vm>                 截当前 frame buffer → PNG
hvm-dbg key <vm> --text "..."           注入字符串文本
hvm-dbg key <vm> --press <keys>         注入按键序列 (e.g. cmd+t, Return)
hvm-dbg mouse <vm> <op>                 鼠标: move / click / scroll
hvm-dbg console <vm> --read|--write     读/写 virtio-console (hvc0), 请求/响应模型
hvm-dbg ocr <vm>                        抓屏 + OCR (Vision framework)
hvm-dbg find-text <vm> "login"          抓屏 + OCR + 返回文本位置
hvm-dbg status <vm>                     VM 运行信息 (不同于 hvm-cli status, 偏 guest)
hvm-dbg boot-progress <vm>              启动阶段判断 (仅根据帧变化 / serial 输出)
hvm-dbg wait <vm> --for text --match "$ " --timeout 60   等 guest 进入某状态
hvm-dbg exec <vm> [--user U --password-from-stdin] -- <cmd>   自动登录 + 跑命令 + 抓 exit code
```

### 通用选项

| 选项 | 说明 |
|---|---|
| `--format human\|json` | 默认 json(hvm-dbg 主要给自动化用) |
| `--timeout <sec>` | 所有涉及等待的命令默认 30s |
| `--quiet` | 仅输出结果 |

## 命令详解

### `screenshot`

```
hvm-dbg screenshot foo                           # stdout binary PNG
hvm-dbg screenshot foo --output shot.png
hvm-dbg screenshot foo --format json             # { "pngBase64": "...", "widthPx": 1920, "heightPx": 1080 }
```

实现:

- VMHost 通过 `VZVirtualMachineView.takeScreenshot()`(若 VZ 提供)或从底层 `CGLayer` / `IOSurface` 截图
- 若 VZ 没直接暴露截图 API, VMHost 内置一个 `offscreen NSView.cacheDisplay(in:to:)` 方案
- VM 未 running → 返回最近一次缓存的缩略图, 无则报错

> **QEMU 后端**: QMP `screendump` → PPM P6 临时文件 (`HVMQemu/QmpClient.swift:screendump`) →
> `PPMReader` 解码到 `CGImage` → PNG 编码 (`HVMQemu/QemuScreenshot.swift`).
> 输出与 VZ 路径同形态 (PNG bytes + 像素尺寸 + sha256), 客户端无感知.

### `key`

```
# 字符串(按 UTF-8 编码为 USB HID scancode 序列)
hvm-dbg key foo --text "ls -la\n"

# 按键序列(组合键)
hvm-dbg key foo --press "cmd+space"
hvm-dbg key foo --press "Return"
hvm-dbg key foo --press "cmd+t cmd+t cmd+w"      # 三次动作
```

key 支持的记号(类似 xdotool):

- 普通字符 `a`, `B`, `1`, `!` 直接按
- 特殊键 `Return`, `Tab`, `Esc`, `Space`, `BackSpace`, `Delete`, `Left`, `Right`, `Up`, `Down`, `Home`, `End`, `PageUp`, `PageDown`, `F1`-`F12`
- 修饰符 `cmd`, `ctrl`, `shift`, `alt` (alt = option)
- 组合用 `+` 连接, 多组合用空格分隔

实现走 `VZUSBKeyboardConfiguration` 提供的键盘通道, VMHost 把记号翻译成 USB HID usage, 按时序注入。

> **QEMU 后端**: 同样的记号经 `QemuKeyMap.parseCombo` 翻译为 QEMU qcode (qkey 名见 QEMU `qkeys.json`),
> 通过 QMP `send-key` 一次提交一组 qcode, holdTime 50ms (字符) / 100ms (组合键) 给 guest 缓冲.
> 字符串走单字符循环, 组合键一次发送同时按下再统一释放. 见 `HVMQemu/QemuInput.swift` + `QemuKeyMap.swift`.

### `mouse`

```
hvm-dbg mouse foo move --to 640,360              # 绝对坐标 (pointer is VZUSBScreenCoordinatePointingDevice, 用绝对定位)
hvm-dbg mouse foo click --at 640,360             # 移到并单击左键
hvm-dbg mouse foo click --at 640,360 --button right
hvm-dbg mouse foo double-click --at 640,360
hvm-dbg mouse foo scroll --at 400,400 --delta-y 5
hvm-dbg mouse foo drag --from 100,100 --to 500,500
```

- 坐标基于 guest 的逻辑像素(与 frame buffer 分辨率一致)
- 必须先获取当前 guest 分辨率: `hvm-dbg status foo` 的 `guestResolution` 字段
- macOS guest 上的 trackpad 设备 (VZMacTrackpadConfiguration) 另有 `--via trackpad` 参数可选, 默认走 USB pointing

> **QEMU 后端**: guest 像素坐标线性映射到 QEMU `input-send-event` 的 abs 规约范围 0..32767
> (`HVMQemu/QemuInput.swift:absMoveEvents`), 然后 QMP `input-send-event` 送 `abs` x/y + `btn` down/up 事件.
> 不依赖 USB pointing device, 也不区分 trackpad — `--via trackpad` 在 QEMU 后端忽略, 一律走 abs.
> 当前 guest 分辨率仍要先取 `hvm-dbg status` (QEMU 后端的 `guestResolution` 由 guestOS 默认尺寸估算).

### `console`

`virtio-console`(hvc0) 在 host 侧由 `ConsoleBridge` 接管: 双向 pipe + tee 到
`<bundle>/logs/console-YYYY-MM-DD.log` + 256 KiB ring buffer。`hvm-dbg console` 走**请求/响应**模型,
不做交互 tty 透传(交互式 shell 走 ssh, 这里是给脚本/agent 用的原子 op):

```
hvm-dbg console foo --read                      # 拉 ring buffer 全量 (json 含 dataBase64 + totalBytes)
hvm-dbg console foo --read --since-bytes 4096   # 拉 [4096, totalBytes) 的增量
hvm-dbg console foo --read --format human       # 把 base64 解码后裸字节直接 stdout (适合 tail -f)
hvm-dbg console foo --write "echo hello\n"      # 把 text 当 UTF-8 写到 guest stdin (不自动加 \n)
hvm-dbg console foo --write-stdin               # 从 host stdin 流式写入 guest stdin
```

`--read` 响应字段:

```json
{ "totalBytes": 18234, "returnedSinceBytes": 4096, "returnedBytes": 14138, "dataBase64": "..." }
```

`returnedSinceBytes` 可能 > 客户端传入的 `sinceBytes` —— 当 sinceBytes 落在 ring 窗口外,
bridge 会把起点上调到窗口左界。客户端拿响应里的 `totalBytes` 当下一轮 `--since-bytes` 即可增量轮询。

Linux guest 默认 getty 监听 `/dev/hvc0`, 用户名/密码登录即可 shell。

macOS guest 不能在 hvc0 起 getty, serial console 只看得到 boot log, 不能交互。
对 macOS, `console --read` 能拿启动日志, `--write` 写入会进 hvc0 但不会有 shell 应答。

> **QEMU 后端**: 没有 virtio-console hvc0, 改走 `-chardev socket,server,wait=off` + `-serial chardev:`
> 暴露 ARM virt 默认串口 (PL011) 到 unix socket (`run/<vm-id>.console.sock`); host 侧
> `QemuConsoleBridge` 与 VZ 同形态接管 — 同一个 ring buffer + 同一份 `<bundle>/logs/console-YYYY-MM-DD.log`.
> 客户端 `--read` / `--write` / `--write-stdin` 行为完全一致, 无 hvc0 / PL011 区分.
> Linux ARM 默认就有 ttyAMA0 串口 console, 走 `serial-getty@ttyAMA0.service` 起登录;
> Windows ISO 装机时 QEMU 仍开 cocoa GUI 窗口, 串口主要给装机日志/调试用.

### `ocr`

```
hvm-dbg ocr foo                                 # 全屏 OCR
hvm-dbg ocr foo --region 100,100,800,600
```

输出:

```json
{
  "widthPx": 1920,
  "heightPx": 1080,
  "texts": [
    { "bbox": [100, 200, 340, 230], "text": "Login:", "confidence": 0.98 },
    { "bbox": [380, 200, 640, 230], "text": "user", "confidence": 0.95 }
  ]
}
```

实现: `Vision` framework `VNRecognizeTextRequest`, 纯本地, 不联网。

### `find-text`

```
hvm-dbg find-text foo "Sign In" --timeout 10
# 轮询抓屏+OCR, 找到返回 bbox+center, 超时退出非零
```

输出:

```json
{
  "match": true,
  "bbox": [820, 500, 980, 540],
  "center": [900, 520],
  "text": "Sign In",
  "screenshotPath": "/tmp/hvm-dbg-shot-abc.png"
}
```

与 `mouse click --at <center>` 结合使用就能在不知坐标的情况下点按钮:

```bash
center=$(hvm-dbg find-text foo "Sign In" | jq -r '.center | "\(.[0]),\(.[1])"')
hvm-dbg mouse foo click --at "$center"
```

### `status`

偏 guest 角度:

```json
{
  "state": "running",
  "guestResolution": { "widthPx": 1920, "heightPx": 1080 },
  "frameBufferFPS": 29.8,
  "consoleBytesSinceBoot": 48291,
  "lastFrameHash": "b1a4...",
  "consoleAgentOnline": true
}
```

`lastFrameHash` 给 AI agent 判断"画面是否变化", 避免重复截屏。

> **QEMU 后端**: `state` 优先取 QMP `query-status` (`running` / `paused` / `shutdown` 等), QMP 未就绪时
> 回退到 `runner.state` (`starting` / `running`). `guestResolution` **不**走实时探测 — 当前 cocoa 自带
> 窗口没有简单 API 取实时尺寸, 用 `GuestOSType.defaultFramebufferSize` 估算 (与 VZ DbgOps 一致).
> `lastFrameSha256` 由最近一次 `screenshot` 调用更新, 没截过一次则为 nil.
> `frameBufferFPS` / `consoleBytesSinceBoot` 当前 QEMU 路径未填, 客户端不应依赖.

### `boot-progress`

启发式判断 guest 处于哪个启动阶段:

1. 无 frame buffer 更新 → `bios`
2. frame buffer 刷新但无文字 OCR → `boot-logo`
3. 出现 "Login:" / "localhost login:" → `ready-tty`
4. 出现 desktop 典型 UI 元素 → `ready-gui`

输出:

```json
{ "phase": "ready-tty", "confidence": 0.82, "elapsedSec": 18 }
```

`confidence < 0.5` 时 `phase=unknown`, 不要用于硬条件分支。

### `wait`

```
hvm-dbg wait foo --for text --match "login:" --timeout 60
hvm-dbg wait foo --for frame-stable --within 2 --timeout 30  # 连续 2 秒 frame hash 不变
hvm-dbg wait foo --for state --eq running --timeout 120
hvm-dbg wait foo --for console --match "Started Login Service"
```

Exit code 0 = 达成, 6 = 超时。

### `exec`(via console)

```
# 已登录的 shell 直接跑命令 (省略 --user)
hvm-dbg exec foo -- /bin/sh -c "uname -r"

# 自动 login: 写 user → 等 Password: → 写 password → 等 shell prompt → 跑命令
echo 'hunter2' | hvm-dbg exec foo --user root --password-from-stdin -- /bin/sh -c "uname -r"

# 命令行带密码 (不推荐, 会进 history)
hvm-dbg exec foo --user root --password hunter2 -- /bin/sh -c "uname -r"
```

实现完全在客户端: 组合 `console.read` / `console.write` 跑状态机:

1. 拿当前 `totalBytes` 当 watermark, 后续轮询都从这个起点之后
2. 写 `\n` 触发 prompt
3. 等到 buffer 末尾命中 `login:` / `Username:` / `Password:` / shell prompt(`$ ` / `# ` / `% `)之一,
   按命中分支决定走登录流程还是直接跑命令
4. 用 uuid sentinel 包裹命令: `echo __HVM_BEGIN_<uuid>__; <cmd>; echo __HVM_END_<uuid>__:$?`
5. 等 END sentinel 出现, 截 BEGIN..END 之间字节当 stdout, 抓 exit code 当退出码

**前置条件**: guest 内 `/dev/hvc0` 起了 getty (Linux 上一般是
`systemctl enable serial-getty@hvc0.service`, Ubuntu cloud image 默认开了)。

**安全约束** (按 CLAUDE.md):
- 推荐 `--password-from-stdin` 而非 `--password` (避免命令行 history 泄露)
- 客户端 / 服务端日志均不打印密码字段, 错误信息也不带
- `console` 的 ring buffer 和日志文件**会**记录 guest 的 echo 输出 — 如果 guest 配 `stty -echo`
  在 password 阶段, 就连这层也不会留痕; 默认配置下密码字符会被 shell 关 echo, 但 `Password:` prompt
  之前的字符可能短暂可见
- exec 是兜底手段, 长期自动化更推荐 ssh 密钥 + 网络

## 协议(VMHost ↔ hvm-dbg)

Unix domain socket, 每条消息 length-prefixed JSON:

```
Frame: [4-byte big-endian length][JSON payload]
```

Request:

```json
{
  "id": "uuid",
  "op": "screenshot" | "key" | "mouse" | "console.read" | "console.write"
        | "status" | "ocr" | "find-text" | ...,
  "args": { ... }
}
```

Response:

```json
{ "id": "uuid", "ok": true, "data": { ... } }
```

或:

```json
{ "id": "uuid", "ok": false, "error": { "code": "...", "message": "..." } }
```

详细协议在 `HVMIPC/Protocol.swift`, `hvm-dbg` 和 VMHost 共享同一份定义, 不做版本协商(两者永远一起构建, 版本必然一致)。

## 与 AI agent 的协作

`hvm-dbg` 的设计**就是**给 AI agent 当 guest 自动化工具:

1. JSON 输出所有命令
2. 子命令原子化, 一个命令一个语义
3. 抓屏 + OCR + 坐标点击三板斧能替代所有 UI 操作
4. `find-text` + `wait` 让 agent 有闭环反馈能力
5. 失败返回结构化 error, 不打印栈到 stdout

### 示例 agent loop

#### 视觉操控 (GUI 装机 / 桌面自动化)

```
while not done:
    screenshot = hvm-dbg screenshot foo --output /tmp/s.png
    ocr = hvm-dbg ocr foo
    next_action = llm.decide(ocr, goal)
    if next_action.type == "click":
        hvm-dbg mouse foo click --at next_action.xy
    elif next_action.type == "type":
        hvm-dbg key foo --text next_action.text
    hvm-dbg wait foo --for frame-stable --within 1 --timeout 10
```

#### 启动阶段编排 (boot-progress 用例)

按阶段路由动作, 避免还在 BIOS / boot-logo 时白跑 OCR:

```bash
while true; do
    phase=$(hvm-dbg boot-progress foo | jq -r '.phase')
    case "$phase" in
        bios|boot-logo) sleep 2 ;;
        ready-tty)      break ;;            # 进了 tty, 后续走 console / exec
        ready-gui)      break ;;            # 进了桌面, 后续走 screenshot / mouse / key
        unknown)        sleep 1 ;;
    esac
done
```

#### Console 增量轮询 (无登录)

`tail -f` 风格读 console, 每次拿 totalBytes 当下次起点:

```bash
since=0
while true; do
    resp=$(hvm-dbg console foo --read --since-bytes "$since")
    since=$(echo "$resp" | jq -r '.totalBytes')
    echo "$resp" | jq -r '.dataBase64' | base64 -d
    sleep 0.5
done
```

#### 装机后跑健康检查 (exec 用例)

```bash
hvm-dbg wait foo --for text --match "login:" --timeout 300
echo "$VM_PASSWORD" | hvm-dbg exec foo \
    --user ubuntu --password-from-stdin --timeout 30 \
    -- /bin/sh -c 'uname -r && systemctl is-system-running'
# exit 0 = 健康, 透传 guest exit code
```

## 不做什么

1. **不实现 guest agent 协议** (qemu-ga / vmware-tools 那种)。原则是零新协议
2. **不做 ssh / scp 包装**: 走 host shell 即可, 那是 user 的事, 不是调试探针的事
3. **不做 record/replay 宏**: 不录制然后回放(脆弱), 要脚本用户自己写
4. **不做 GUI UI 元素识别**: OCR 够用, 深度 AX 树解析出 VZ 范围
5. **不连外网发模型请求**: OCR 纯本地, agent 侧 LLM 调用不是 hvm-dbg 职责

## 退出码

与 `hvm-cli` 一致(见 [CLI.md](CLI.md) 退出码表), 额外:

| code | 含义 |
|---|---|
| 20 | VM 未运行, 无法操作 |
| 21 | IPC 连接失败(socket 不存在/拒绝) |
| 22 | guest console agent 不在线(仅 console / exec 相关) |
| 23 | OCR 无结果 / find-text 未找到 |

## 安全

- 所有命令检查调用方 uid 是否等于 VMHost 的 uid, 否则拒绝
- socket 文件权限 `0600`
- 日志里抹掉 `--password` / `--text` 中疑似敏感内容: 若 `--text` 长度 > 20 字符或包含 `pass|token|key|secret` 关键字, 日志记 `--text *** (redacted, 42 chars)`

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| H1 | 是否暴露 `clipboard get/set` | 需 guest 支持, macOS 可用, Linux 需 spice-vdagent, MVP 不做 | M3 |
| H2 | 是否提供 `wait --for pixel-at --equals <color>` | 不做, `find-text` + `frame-stable` 已能覆盖 | 已决 |
| H3 | 多个 `hvm-dbg` 并发连同一 VM 是否允许 | 允许, VMHost 侧按 id 串行处理 | 已决 |

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — VMHost 进程模型
- [CLI.md](CLI.md) — hvm-cli, 职责分工
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — 键盘/鼠标设备 VZ 侧

---

**最后更新**: 2026-04-26 (S-2: 加 QEMU 后端等价实现附注; 主要差异在 QMP screendump / send-key qcode / input-send-event abs / serial PL011)
