# HDP-GUI: hvm-dbg ↔ HVM GUI 测试协议

> 状态: **代码已合入 (2026-05)** (PR-G1/G2/G3/G5). D-G2 决策走自家 ProbeRegistry 不走 NSAccessibility (macOS 14+ a11y 实测不暴露给程序内查询). 现状回写 [../v1/DEBUG_PROBE.md](../v1/DEBUG_PROBE.md) "gui 子命令" 节 + [../v1/GUI.md](../v1/GUI.md) "加密 VM GUI 集成" 节.
>
> 关联 TODO: [TODO.md](TODO.md) #G1 GUI 自动化测试通道 — 已 Done
> 父稿: [GUI_ENCRYPTION.md](GUI_ENCRYPTION.md) PR-11 (代码已合入)

## 背景

CLAUDE.md 已写"调试/诊断工作方式约束":
- 禁止 osascript / AppleScript UI scripting
- guest 内操作走 hvm-dbg (key/mouse/screenshot/ocr/exec)
- 缺功能立即扩展 hvm-dbg, 不绕路

但 **hvm-dbg 现有命令全部针对 guest VM 内** (qemu-guest-agent / display framebuffer / ocr) — 没有针对 **HVM 主进程 GUI 自身** 的探针. 现状下 GUI 验证只能:
1. 我自己手动开 .app 点
2. 让用户帮点 (违反 CLAUDE.md "不让用户手动操作 GUI" 约束)
3. 靠 Cmd-line + e2e 行为间接推断

PR-11 (GUI 加密) 落地后的真机验证 (PR-11f) 卡住的就是这个: 没法自动化点 "Create VM" / 输密码框 / 点详情页加密区按钮.

本稿设计一层 **HDP-GUI** 协议 — 让 hvm-dbg 通过 Unix socket 跟 HVM GUI 主进程对话, 实现:
- screenshot (主窗口 / 当前 dialog)
- click / right-click (按钮 / 控件)
- 输入文字 / 密码框
- 列出当前可见控件 (accessibility tree)
- 切换 sidebar VM / 触发各菜单动作
- 监听弹窗 (新 dialog 出现时通知)

跟 hvm-dbg 现有 guest 探针并行 — guest 内行为走 qemu-guest-agent, GUI 自身行为走 HDP-GUI.

## 目标 + 范围

**做**:
- HVM 主进程内开一个 Unix domain socket 服务端 (HDP-GUI server), `~/Library/Application Support/HVM/run/hvm-dbg-gui.sock`
- 协议: line-delimited JSON-RPC (跟现有 IPC 风格一致)
- 操作集 (MVP):
  - `gui.list` — 列当前可见 view tree (id / type / frame / label / 是否可点)
  - `gui.screenshot` — 截当前主窗口 + 任何弹层 dialog 的合成图 (PNG)
  - `gui.click` — 点指定 id 的控件 (走 simulated mouseDown/mouseUp 事件 → 等价用户点击)
  - `gui.type` — 给当前 firstResponder textField 输文字
  - `gui.keypress` — 发 keystroke (Enter / Esc / Tab 等)
  - `gui.dialog.current` — 返回当前打开的 dialog 名 (createVM / clone / encryptionPassword / ...) + 状态
  - `gui.event.subscribe` — 订阅事件流 (dialog open/close, refreshList, error)
- hvm-dbg 子命令: `hvm-dbg gui list / screenshot / click / type / keypress / dialog`
- 仅 Debug build 启用 (release 不开 server, 防泄露 host UI)
- 鉴权: 默认无 (sock 在用户 home 0600); 后续可加 token

**不做**:
- 远程 (跨机) 控制
- 跨进程 view 注入 (例如改 SwiftUI state) — 仅模拟用户交互
- 持久化录制 / 回放
- 替代 XCTest UI testing 框架 (那是产品化测试; 本稿目标是 agent 自动化)

## 选型对比

### D-G1: 协议形式

| 方案 | 实现 | 优点 | 缺点 | 选用 |
|---|---|---|---|---|
| **A. Unix socket + 行 JSON-RPC** | sockets/hvm-dbg-gui.sock + JSONLines | 跟现有 HVMIPC 一致, 复用 SocketServer/SocketClient | 调试稍繁琐 | ✅ |
| B. HTTP / REST | HTTPListener + JSON | 用 curl 也能调 | 引入 HTTP server 重 | ✗ |
| C. Mach port / NSXPCService | macOS 原生 | 类型安全 | 重, hvm-dbg 也得 link Mach API | ✗ |
| D. AppleScript / NSAccessibility | 系统通用 | 零代码 | CLAUDE.md 已禁; 黑盒不稳 | ✗ |

**选 A**. 理由: 复用 HVMIPC.SocketServer (PR-9 期已建), 协议形式跟 IPCRequest/IPCResponse 一致. 工作量最小.

### D-G2: 控件 ID 体系

要点: hvm-dbg 必须能稳定指认控件 — "右上角 Create 按钮", "密码框", "ISO 路径 input".

| 方案 | 实现 | 选用 |
|---|---|---|
| **A. 显式 accessibilityIdentifier (`.accessibilityIdentifier("create.start")`)** | SwiftUI 标准 `.accessibilityIdentifier(_:)` 修饰符 | ✅ — 静态可控, 不依赖文案 |
| B. 按 view 类型 + 文案 fuzzy match | "Button labeled 'Create'" | ✗ — 文案改 / i18n 即崩 |
| C. 按坐标 click | "click at (240, 380)" | ✗ — 窗口 resize / 动画一变就错 |

**选 A**. 强制约束: 所有需要测试的控件必须打 `.accessibilityIdentifier`. 命名规范 `<scene>.<role>.<name>` 例:
- `sidebar.row.<vmDisplayName>`
- `detail.button.start`
- `dialog.createVM.input.name`
- `dialog.createVM.toggle.encrypt`
- `dialog.createVM.input.password`
- `dialog.createVM.button.create`
- `dialog.encryptionPassword.input.password`
- `dialog.encryptionPassword.button.submit`

### D-G3: 截图实现

| 方案 | 实现 | 选用 |
|---|---|---|
| **A. NSWindow.dataWithPDF + NSImage** | 当前 keyWindow 截图 (含 SwiftUI 内容) | ✅ — 原生 Cocoa, 含 dialog |
| B. CGWindowListCreateImage | 走 ScreenCaptureKit | ✗ — 需要 screen recording 权限, 用户体验差 |
| C. SwiftUI ImageRenderer | 仅截 SwiftUI subview | ✗ — 拿不到完整窗口 |

**选 A** (`NSBitmapImageRep(focusedViewRect:)` 或 `WindowController.window?.contentView?.bitmapImageRepForCachingDisplay`). 直接拿 main window contentView 渲染为 PNG, 走 socket 返回 base64.

### D-G4: 事件订阅 (subscribe)

| 方案 | 实现 | 选用 |
|---|---|---|
| **A. socket 内长连接 push (server → client)** | Client 发 `gui.event.subscribe`, server 持长连接 push JSON 行 | ✅ — 跟 QMP event 风格一致 |
| B. 客户端 polling | hvm-dbg gui dialog 不停查 | ✗ — 浪费, 错过 transient 状态 |

**选 A**. SocketServer 支持长连接, 复用. hvm-dbg 端 `--watch` flag 跑 subscribe 循环.

### D-G5: 鉴权 / 安全

| 方案 | 实现 | 选用 |
|---|---|---|
| **A. Unix socket + 0600 + 用户 home** | filesystem ACL 兜底 | ✅ MVP — 同用户进程能开 |
| B. + token (启动 GUI 时打到 stderr) | hvm-dbg 拿 token 作 first request | 后续加 |
| C. 完全开放, 任何能 connect 的都能控 | — | ✗ — 防 lima/colima 等无关进程误连 |

**选 A**. 默认无 token. 0600 socket 在 ~/Library/Application Support/HVM/run/. 同用户其他进程能拨, 但加密 / VM 数据不在协议范围内 (协议只能模拟点击, 不能 dump 内存).

## 实现要点

### 1. 协议 schema

请求:
```json
{"id": 1, "op": "gui.list", "args": {"scope": "dialog"}}
{"id": 2, "op": "gui.click", "args": {"identifier": "dialog.createVM.button.create"}}
{"id": 3, "op": "gui.type", "args": {"identifier": "dialog.encryptionPassword.input.password", "text": "secret123"}}
{"id": 4, "op": "gui.screenshot", "args": {"format": "png"}}
{"id": 5, "op": "gui.event.subscribe", "args": {}}
```

响应:
```json
{"id": 1, "ok": true, "data": {"items": [{"identifier": "dialog.createVM.button.create", "label": "Create", "frame": [...], "clickable": true}]}}
{"id": 2, "ok": true}
{"id": 4, "ok": true, "data": {"png_base64": "..."}}
```

事件 (subscribe 后 server 推):
```json
{"event": "dialog.opened", "name": "encryptionPassword", "vmId": "..."}
{"event": "dialog.closed", "name": "encryptionPassword"}
{"event": "list.refreshed", "vmCount": 5}
```

错误:
```json
{"id": 2, "ok": false, "error": {"code": "gui.identifier_not_found", "message": "no view with id 'dialog.x.y'"}}
```

### 2. Server 端 (HVM 主进程)

新模块 `HVMGuiProbe` (新 target, 不入主 HVMCore 防 release 误开):

```
HVMGuiProbe/
├── ProbeServer.swift         # SocketServer 包装, op dispatcher
├── ViewRegistry.swift        # accessibilityIdentifier → NSView/SwiftUI view 映射
├── ScreenshotRenderer.swift  # NSWindow → PNG
├── ClickSimulator.swift      # 模拟 NSEvent.mouseDown/up post 给目标 view
├── TypeSimulator.swift       # firstResponder 设置 + insertText
└── EventBus.swift            # dialog.opened / closed 等事件流
```

主进程启动期 (HVMApp.applicationDidFinishLaunching):

```swift
#if DEBUG_GUI_PROBE
ProbeServer.start(socketPath: HVMPaths.runRoot.appendingPathComponent("hvm-dbg-gui.sock"))
#endif
```

`DEBUG_GUI_PROBE` 由 SwiftPM `swiftSettings: [.define("DEBUG_GUI_PROBE", .when(configuration: .debug))]` 触发. release build 不开. 但 `make build` 默认 release — 我们也要让 build/HVM.app 默认开 (因为本机测试 .app 是 release-signed, 没 debug build). 改为通过 env var `HVM_GUI_PROBE=1` 触发, 可在 release build 上 opt-in.

### 3. SwiftUI / AppKit 控件接 accessibilityIdentifier

CLAUDE.md UI 控件约束已经规定所有按钮/输入框走 HVMTextField/HVMToggle 等自家组件. 这些组件统一加 `.accessibilityIdentifier(_:)` 修饰符, 业务侧调用时传 id:

```swift
HVMTextField("name", text: $name)
    .accessibilityIdentifier("dialog.createVM.input.name")
```

或者干脆给自家组件加 `id` 参数:

```swift
HVMTextField("name", text: $name, identifier: "dialog.createVM.input.name")
```

**约束扩展**: 所有需要被测试的对话框 / 按钮 / 输入框必须传 identifier. 允许业务侧不传 (对外展示性控件可以无 id), 但写测试就需要补.

### 4. 模拟点击

走 NSApp.sendEvent(_:) 模拟 NSEvent. 关键: 找 view → 算 view 在 window 内的中心点 → 构造 mouseDown + mouseUp event → post 给 window:

```swift
let view = registry[identifier]  // NSHostingView 内的 SwiftUI view 找到对应 NSView
let center = view.frame.midPoint  // 转 window coords
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: center, ...)
let up   = NSEvent.mouseEvent(with: .leftMouseUp, ...)
view.window?.sendEvent(down)
view.window?.sendEvent(up)
```

### 5. hvm-dbg 端 (新子命令)

```
hvm-dbg gui list [--scope window|dialog|sidebar]
hvm-dbg gui screenshot --output /tmp/hvm.png
hvm-dbg gui click --identifier dialog.createVM.button.create
hvm-dbg gui type --identifier dialog.encryptionPassword.input.password --text secret123
hvm-dbg gui keypress --key return        # return / esc / tab / a-z / 0-9
hvm-dbg gui dialog                       # 显示当前 dialog 名 + 状态
hvm-dbg gui watch                        # 长连接订阅事件
```

## 风险与待验证项

| 编号 | 风险 | 验证 | 阻断 |
|---|---|---|---|
| **G-R1** | accessibilityIdentifier 在 SwiftUI 非 leaf view 是否被 NSAccessibility 透传 | 实测 — SwiftUI 14+ `.accessibilityIdentifier` 走 NSAccessibility identifier, registry 用 `accessibilityChildren` 递归扫主窗口 | P0 |
| **G-R2** | 模拟 NSEvent 是否触发 SwiftUI Button onAction | NSEvent 经 NSWindow 事件链 → SwiftUI Button hit-test → action. 实测过 (osc-* 老 issue 提过) | P0 |
| G-R3 | dialog open/close 事件如何感知 | AppModel @Published 字段变化时 publisher → ProbeServer.EventBus push | P1 |
| G-R4 | screenshot 含 dialog 蒙底 + 卡片 | NSWindow.contentView 的 bitmap 包含整层 layer | 已论证 |
| **G-R5** | release build 默认是否开 server | `HVM_GUI_PROBE=1` env 触发. 不开时不 import HVMGuiProbe (避免 release 体积 / signing 暴露) | P1 |
| G-R6 | 多窗口 (detached QEMU 窗口) 怎么处理 | MVP 仅支持主窗口; detached 推后 | 已决 |
| **G-R7** | 安全: 同用户其他 daemon 能 connect → 模拟点击恶意操作 | 0600 sock + 用户 home, 跟 socket_vmnet 同安全模型. 加 token 推后 | 已论证 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-G1** | HVMGuiProbe 模块基础: SocketServer + JSON-RPC dispatcher + `gui.screenshot` (最简 op) + `HVM_GUI_PROBE=1` env 开关 + hvm-dbg `gui screenshot` 子命令. 真机: 跑 GUI + hvm-dbg gui screenshot --output /tmp/x.png 看到主窗口 | 0.5 天 | 待开 |
| **PR-G2** | ViewRegistry + accessibilityIdentifier 扩展自家 UI 组件 (HVMTextField/HVMToggle/HVMModal/Button styles 加 id 参数). 加 `gui.list` op | 0.5 天 | 待开 |
| **PR-G3** | ClickSimulator + TypeSimulator + KeyPressSimulator. 加对应 hvm-dbg 子命令. 真机: 用 hvm-dbg 自动点开 Create VM dialog → 输 name → 点 Create | 0.5 天 | 待开 |
| **PR-G4** | EventBus + `gui.event.subscribe` + hvm-dbg gui watch. AppModel @Published 字段加 publisher → push event | 0.5 天 | 待开 |
| **PR-G5** | 给现有 dialog 全部加 accessibilityIdentifier (CreateVM / EncryptionPassword / Clone / Snapshot / DiskAdd / DiskResize / EditConfig / Confirm / Error). 文档登记 ID 表 | 0.5 天 | 待开 |
| **PR-G6** | docs 同步: docs/v1/DEBUG_PROBE.md 加 GUI 节; CLAUDE.md "调试约束" 加 hvm-dbg gui xxx 自动化优先 | 0.2 天 | 与 PR-G5 合 |

合计 ~2.5 天 / 1 人. PR-G1 → G3 串行 (依赖); G4 / G5 可并行.

每个 PR `make build` 通过 + 自动化测试一次 (跑 hvm-dbg 给当前 PR 范围的功能).

## 与 PR-11 (GUI 加密) 的关系

PR-11f 真机 e2e **依赖** PR-G1 + PR-G3 (至少 screenshot + click + type). 时序建议:

1. **现状**: PR-11a/b/c stub 已落, 11d/e/f/g 待开
2. **方案 1**: 暂停 PR-11c full impl, 先做 PR-G1~G3 (~1.5 天), 再回 PR-11c~g 时已能自动化测
3. **方案 2**: 完成 PR-11c~e 主代码不动, 11f 时再做 PR-G — 但那时 11c~e 没自动化验证, 容易漏 bug

**主张方案 1** (PR-G 先行). 投入 1.5 天换后续所有 GUI PR 的自动化验证 + agent 调试能力, ROI 高. 用户每次新加 GUI 我都能自动测.

## 未决事项

| 编号 | 问题 | 主张 | 决策时机 |
|---|---|---|---|
| **D-G1** | 协议形式 | A: Unix socket + line JSON-RPC | 本稿 |
| **D-G2** | 控件 id 体系 | A: 显式 accessibilityIdentifier, 命名 `<scene>.<role>.<name>` | 本稿 |
| D-G3 | 截图实现 | A: NSWindow contentView bitmap | 本稿 |
| D-G4 | 事件订阅 | A: socket 长连接 push | 本稿 |
| D-G5 | 鉴权 | A: 0600 sock + 用户 home, MVP 无 token | 本稿 |
| **D-G6** | release vs debug build 启用策略 | `HVM_GUI_PROBE=1` env 触发, release 默认不启 server (但 module 仍 link, 体积 +~50KB) | 本稿 |
| D-G7 | 协议是否复用 HVMIPC.IPCRequest/Response | 复用 schema (op/id/data/error 字段) 但走独立 socket — IPCRequest 已是 [String: String], JSON 灵活性更好, **新 schema** | 本稿 |
| D-G8 | accessibilityIdentifier 强制约束级别 | "新加 dialog 必须打 id, 老 dialog PR-G5 一次性补完" | 本稿 |
| D-G9 | 是否走 PR-11 之前先做 G1-G3 | **主张是**: 1.5 天投入换 GUI 自动化能力, 后续所有 GUI PR 受益 | **本稿核心待决** |

## 设计变更日志

### 2026-05-04 v1 — 本稿

初稿. 用户中断 PR-11c 时主动提议. 关键决策:
- 选 Unix socket + JSON-RPC (D-G1)
- 强制 accessibilityIdentifier (D-G2)
- env 开关启用 (D-G6)
- 主张 PR-G 先行 (D-G9)

## 相关文档

- 关联设计稿 [GUI_ENCRYPTION.md](GUI_ENCRYPTION.md) — PR-11f 真机验证依赖此协议
- 现有 hvm-dbg [docs/v1/DEBUG_PROBE.md](../v1/DEBUG_PROBE.md) (待回写 GUI 节)
- 现有 IPC: [HVMIPC/SocketServer.swift](../../app/Sources/HVMIPC/SocketServer.swift) — 复用模式参考
- [CLAUDE.md](../../CLAUDE.md) "调试/诊断工作方式约束" 节 (本稿合入后补"GUI 自动化优先")
