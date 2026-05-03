# 调试探针 (`hvm-dbg`)

## 目标

- 程序化方式在 guest 内做操作 (看屏 / 敲键 / 鼠标 / 串口 / qemu-guest-agent 跑命令)
- **替代** CLAUDE.md 明确禁止的 `osascript` / AppleScript UI scripting
- 双后端通路 (VZ + QEMU) 同形态对外, 客户端无感知差异
- 给 AI agent / 自动化脚本 / 人工调试统一用

## 为什么不用 osascript

CLAUDE.md 「调试 / 诊断工作方式约束」明文:

> **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(脆弱、依赖屏幕坐标和辅助功能权限, 不可复现)

osascript 致命问题:

1. 依赖辅助功能权限 — 每次需用户点允许
2. 依赖 host 端绝对坐标 — 分辨率改了就废
3. 不能跨进 guest, 只能动 host 的 GUI
4. 与 AppKit 版本耦合, 上游升级就崩

`hvm-dbg` 的替代 — 直接走 VZ / QMP / HDP 已暴露的公开 API:

| 需求 | osascript | hvm-dbg |
|---|---|---|
| 敲键 | `keystroke` | `hvm-dbg key foo --press cmd+t` → VZ keyboard / QMP `send-key` qcode |
| 点击 | `click at {x,y}` | `hvm-dbg mouse foo click --at x,y` → VZ pointer / QMP `input-send-event` abs |
| 抓屏 | `screencapture` 全屏算位置 | `hvm-dbg screenshot foo` → VZ frame buffer / QMP `screendump` |
| 跑命令 | 进 guest 装 ssh | `hvm-dbg exec.guest foo --bin powershell.exe` → qemu-guest-agent |

## 定位

- `hvm-cli`: 管 host 侧 — 启 / 停 VM, 改 config, 管磁盘 / snapshot
- `hvm-dbg`: 管 guest 侧 — 截屏 / 输入注入 / console / qemu-ga
- 两者无重叠, 互不调彼此

## 工作原理

`hvm-dbg` 是**客户端**, 连到 VMHost 的 IPC socket (`<bundle>/.lock` 记录 `socketPath`), 让 VMHost 代调 VZ / QMP / HDP — 因为这些 API 必须在持有 VM 的进程里。

```
hvm-dbg ──IPC──▶ HVMHost ──VZ API / QMP / HDP──▶ VM
         Unix     (持 VZVirtualMachine 或拉起 QEMU 子进程)
```

协议: length-prefix JSON (`HVMIPC/Protocol.swift`), `IPCOp.dbg*` 一族 case (`dbg.screenshot` `dbg.key` `dbg.mouse` `dbg.ocr` `dbg.find_text` `dbg.boot_progress` `dbg.console.read` `dbg.console.write` `dbg.display.info` `dbg.display.resize` `dbg.exec.guest` 等)。两端永远一起构建, 不做版本协商。

## 双后端通路

- **VZ 后端**: `screenshot` 走 NSView cacheDisplay → CGImage; `key` / `mouse` 走 `VZUSBKeyboard` / `VZUSBScreenCoordinatePointingDevice`; `console` 走 virtio-console hvc0 + `ConsoleBridge` ring buffer
- **QEMU 后端**: `screenshot` 走 QMP `screendump` → PPM P6 → CGImage (`HVMQemu/QemuScreenshot.swift`); `key` 走 `QemuKeyMap.parseCombo` 翻 qcode + QMP `send-key`; `mouse` 走 abs 0..32767 + QMP `input-send-event`; `console` 走 ARM virt PL011 串口 unix socket + `QemuConsoleBridge`; 额外有 `exec.guest` 走 qemu-guest-agent JSON-RPC

客户端命令完全一致, 后端差异在 VMHost 内部分发 (见 `QemuHostEntry.swift::handleDbg*`)。

## 扩展原则 (CLAUDE.md 必须遵守)

1. **零新协议**: 只包装已暴露的 VZ API / QMP / HDP / qemu-guest-agent 协议, 不实现私有 guest agent
2. **碰到能力缺失立即扩展 hvm-dbg, 不绕路**: 凡是 "现有功能不能完成 X" 时, 新加子命令到 hvm-dbg + 配套 host 端 `IPCOp.dbgXxx` + `handleDbgXxx` handler, **不**让用户 powershell hack / inline shell 绕开
3. **命令粒度对 AI 友好**: 原子操作, 输出 JSON
4. **输出稳定**: 字段名不随版本变, 新增字段向后兼容

## 子命令清单

入口 `app/Sources/hvm-dbg/HvmDbg.swift` 注册:

```
hvm-dbg screenshot <vm> [--output X.png] [--format json]   抓 framebuffer → PNG
hvm-dbg status <vm>                                         guest 视角运行信息 (state / 分辨率 / lastFrameSha)
hvm-dbg key <vm> --text "..." | --press <combo>             键盘事件 (cmd+t / Return / 字符串)
hvm-dbg mouse <vm> move|click|double-click|drag|scroll      鼠标事件 (abs 坐标)
hvm-dbg ocr <vm> [--region x,y,w,h]                         抓屏 + Vision framework OCR
hvm-dbg find-text <vm> "Sign In" [--timeout N]              抓屏 + OCR + 返回 bbox / center
hvm-dbg wait <vm> --for text|state|frame-stable ...         轮询等达成态
hvm-dbg boot-progress <vm>                                  启动阶段 (bios/boot-logo/ready-tty/ready-gui)
hvm-dbg console <vm> --read [--since-bytes N] | --write     串口请求 / 响应模型
hvm-dbg exec <vm> [--user U --password-from-stdin] -- <cmd> 通过 console 自动登录 + 跑命令 (Linux 需 hvc0 / ttyAMA0 起 getty)
hvm-dbg exec.guest <vm> --bin <exe> [--args] [--ps] [--cmd] 通过 qemu-guest-agent 跑命令 (Windows guest 必备)
hvm-dbg display.info <vm>                                   guest 真实 framebuffer 尺寸 (验证 dynamic resize)
hvm-dbg display.resize <vm> --width W --height H            host → guest dynamic resize (HDP RESIZE_REQUEST + vdagent MONITORS_CONFIG)
hvm-dbg qemu-launch <vm> [--print-args] [--shutdown-timeout N]   调试: 直接拉起 QEMU 后端 (绕过 hvm-cli start 主流程)
```

通用选项: `--format human|json` (json 默认偏 hvm-dbg 的自动化场景, 各命令默认值不一); `--timeout` 30s 起步。

## 关键命令补充

### `screenshot`

VZ 路径: `VZVirtualMachineView` cacheDisplay; QEMU 路径: QMP `screendump` 写 PPM 到 `/tmp/<uuid>.ppm` → 客户端读 → CGImage → PNG。客户端拿到的输出形态一致 (PNG bytes + 像素尺寸 + sha256)。

### `key`

记号 (类似 xdotool): 普通字符 `a/B/1/!`; 特殊键 `Return Tab Esc Space BackSpace Delete Left Right Up Down Home End PageUp PageDown F1..F12`; 修饰符 `cmd ctrl shift alt`; `+` 连接, 多组合空格分隔。QEMU 后端走 `QemuKeyMap.parseCombo` 翻 qcode + QMP `send-key` (holdTime: 字符 50ms / 组合键 100ms)。

### `mouse`

绝对坐标 (基于 guest 当前像素尺寸, 先 `display.info` 拿)。QEMU 后端归一化到 abs 0..32767 走 `input-send-event`, 不区分 trackpad/USB pointing。

### `console`

请求 / 响应模型, 不做交互 tty 透传。host 侧 ring buffer 256 KiB + tee 到 `<bundle>/logs/console-YYYY-MM-DD.log`:

```
hvm-dbg console foo --read                       全量
hvm-dbg console foo --read --since-bytes 4096    增量 (拿响应 totalBytes 当下次起点)
hvm-dbg console foo --read --format human        裸字节直接 stdout
hvm-dbg console foo --write "echo hello\n"       写 guest stdin
hvm-dbg console foo --write-stdin                host stdin 流式
```

QEMU 后端走 ARM virt PL011 串口到 unix socket (`run/<vm-id>.console.sock`); Linux ARM 默认 `serial-getty@ttyAMA0.service` 可登录。

### `exec` vs `exec.guest`

- `exec`: 客户端状态机, 通过 `console.read` / `console.write` 跑 `login → password → uuid sentinel 包裹命令` (Linux guest 内 hvc0 / ttyAMA0 起 getty 必需)
- `exec.guest`: 通过 qemu-guest-agent JSON-RPC (`guest-exec` + `guest-exec-status`), 直拿 stdout / stderr (base64) + exit code, **绕过键盘 / OCR / 鼠标**, 跨平台。Windows guest 走 powershell.exe / cmd.exe (`--ps` 优先 / `--cmd` 一行包 `cmd.exe /C`)。优先用此命令做行为验证, OCR 文本判断成败误识率高 (CLAUDE.md「端到端验证用 hvm-dbg」)

### `boot-progress`

启发式: 无 fb 更新 → `bios`; fb 刷新但无 OCR 文字 → `boot-logo`; OCR 命中 `Login: / localhost login:` → `ready-tty`; desktop UI 元素 → `ready-gui`。`confidence < 0.5` 时 phase = `unknown`。

CLAUDE.md「Boot 装机 timing 上限 20s」: VM 启动到 Setup / desktop 渲染**不会超过 20 秒**。任何状态卡同一帧超过 20s 默认判失败, 不要 `ScheduleWakeup` 大于 30s 等待 boot 进度。

## AI agent 协作约定 (CLAUDE.md 调试约束)

1. **禁止 osascript / AppleScript UI scripting 模拟 GUI 点击**
2. **自主调试不让用户操作 GUI**: VM 需要 restart 自己 stop + start, 不让 user "请重启"; 自动化卡死再告诉用户单一 minimal action + why
3. **hvm-dbg 缺功能时扩展, 不绕路**: 新加 `Commands/XxxCommand.swift` + `IPCOp.dbgXxx` + `handleDbgXxx`
4. **端到端验证优先 `exec.guest` 拿 stdout / 退出码**, 不依赖 OCR 文本判断 (Win 控制台 / 中文 IME 误识率高)
5. **验证 framebuffer 状态优先 `screenshot --output X.png`** + `Read X.png` 自己肉眼看, 不依赖 OCR 文本

### 示例 agent loop

视觉操控:

```
while not done:
    hvm-dbg screenshot foo --output /tmp/s.png
    ocr = hvm-dbg ocr foo
    next = llm.decide(ocr, goal)
    if next.type == "click":
        hvm-dbg mouse foo click --at next.xy
    elif next.type == "type":
        hvm-dbg key foo --text next.text
    hvm-dbg wait foo --for frame-stable --within 1 --timeout 10
```

阶段路由:

```bash
while :; do
    phase=$(hvm-dbg boot-progress foo | jq -r '.phase')
    case "$phase" in
        bios|boot-logo) sleep 2 ;;
        ready-tty|ready-gui) break ;;
        unknown) sleep 1 ;;
    esac
done
```

Windows guest 跑命令验证 (无须 OCR):

```bash
hvm-dbg exec.guest foo --ps "Get-PnpDevice -Class Display | Format-List"
# json 默认 base64 解码 stdout / stderr, 退出码透传
```

## 退出码

与 `hvm-cli` 一致 (见 [CLI.md](CLI.md)), 加:

| code | 含义 |
|---|---|
| 20 | VM 未运行, 无法操作 |
| 21 | IPC 连接失败 (socket 不存在 / 拒绝) |
| 22 | guest console agent 不在线 (console / exec 相关) |
| 23 | OCR 无结果 / find-text 未找到 |

## 安全

- IPC socket 文件权限 `0600`, uid 校验拒绝跨用户调用
- 日志抹掉 `--password` 参数, redact 关键字 `pass|token|key|secret`

## 不做什么

1. 不实现私有 guest agent 协议 (qemu-ga / vmware-tools 风格已经够用 — qemu-guest-agent 是上游官方协议, 不算"新协议")
2. 不做 ssh/scp 包装 — 用户自己的事
3. 不做 record/replay 宏
4. 不连外网发模型请求 — OCR 纯本地 Vision

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — VMHost 进程模型
- [CLI.md](CLI.md) — `hvm-cli`, 职责分工
- [DISPLAY_INPUT.md](DISPLAY_INPUT.md) — VZ / QEMU 输入设备
- [QEMU_DISPLAY_PROTOCOL.md](QEMU_DISPLAY_PROTOCOL.md) — HDP framebuffer + RESIZE_REQUEST 协议

---

**最后更新**: 2026-05-04
