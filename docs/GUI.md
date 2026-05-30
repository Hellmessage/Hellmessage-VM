# GUI.md — 新 GUI 现状文档 (HVMUI 组件库 + NewGUIStore + 业务页)

> 现状文档 · 基于 `app/Sources/HVM/GUI/**` 真实代码. 描述当前唯一 GUI 的结构与约束,
> 不含历史 VZ / 老 `UI/**` 内容 (二者已随 QEMU-only 转向退役删除).
>
> 设计稿沉淀: `docs/v4/NEW_GUI.md` (主线) + `NEW_GUI_MAIN_LAYOUT.md` / `NEW_GUI_VM_DETAIL.md` /
> `NEW_GUI_ENCRYPTION.md` (业务页 #1/#2/#3) + `docs/v3/HVM_DBG_GUI_PROTOCOL.md` (probe 协议).

---

## 1. 定位

- **唯一 GUI 走 `app/Sources/HVM/GUI/**`**. 老 GUI (`app/Sources/HVM/UI/**`) 已随
  QEMU-only 转向退役删除, 入口不再分叉. `app/Sources/HVM/main.swift` 在 GUI 模式直接
  `NewGUIAppLauncher.run()` (无 `GUI=new` 运行时分支 — 该开关含义即"恒开").
- **黑色深灰固定深色主题** (Linear 风). `NSApp.appearance = .darkAqua`, 不跟随系统主题.
  主底 `bgBase = #08090A` (中性近黑, 不纯黑).
- **组件 Showcase 退路**: 默认进业务页 `MainLayoutView`; 环境变量 `HVM_GUI_SHOWCASE=1`
  时退回 `NewGUIRootView` 组件 Showcase (`NewGUIApp.swift` 内, Theme token / 各组件
  living doc, 给视觉回归 + hvm-dbg gui 自动化用).
- **目录结构** (`app/Sources/HVM/GUI/`):
  - `NewGUIApp.swift` — AppKit 入口 + Showcase 演示页
  - `Theme/` — `HVMTheme` namespace token (color/font/space/radius/border/motion)
  - `HVMUI.swift` + `Components/` + `Dialogs/` + `Overlay/` — `HVMUI` 组件库
  - `Store/NewGUIStore.swift` — `@Observable` 数据 store
  - `Layout/` — 业务页 (主界面 `MainLayoutView` / sidebar / `Detail*Section`)
  - `Display/` — QEMU 画面嵌入 (`QemuFramebufferView` / `QemuFanoutSession`)

---

## 2. 入口与窗口 (`NewGUIApp.swift`)

纯 AppKit `NSApplication` runloop (非 SwiftUI `App` 生命周期), 由 `NewGUIAppLauncher.run()`
拉起 `NewGUIAppDelegate`.

`applicationDidFinishLaunching`:

- `NSApp.appearance = .darkAqua` + `setActivationPolicy(.regular)`.
- 根 view 选择: `HVM_GUI_SHOWCASE=1` → `NewGUIRootView()`, 否则 → `MainLayoutView()`;
  外层套 `.hvmDialogHost()` (dialog 渲染根, 见 §4) 再交给 `NSHostingController`.
- **窗口最小尺寸三件套** (锁 1080×720): root view `.frame(minWidth:minHeight:)` +
  `host.sizingOptions = .minSize` + `win.contentMinSize`. 不用 `win.minSize` (含 28px
  标题栏会让 content 被压小).
- `win.isReleasedWhenClosed = false`; `win.delegate = self` 拦截红色 X.
- 窗口出现后 `makeFirstResponder(nil)` (async 到下一 runloop) 清掉 AppKit 默认把首个
  文本框设为 firstResponder 并选中内容的行为.
- `ProbeServer.start()` — HDP-GUI probe server (`HVM_GUI_PROBE=1` 时起 unix socket 接
  `hvm-dbg gui`).

**tray 隐藏行为** (代码所示):

- 点红色 X (`windowShouldClose`) / Cmd+Q (`applicationShouldTerminate`) 都**不真退出**,
  走 `hideToTray()` — `window.orderOut(nil)` + 切 `.accessory` (Dock 图标消失, 仅剩状态栏
  tray 图标).
- 状态栏 tray 图标 (`shippingbox.fill` template) 菜单两项: "显示 HVM 主窗口" /
  "退出 HVM". 仅 tray 菜单"退出 HVM" 设 `userRequestedQuit = true` 后才放行真退出.
- 点 Dock / Finder 重开 (`applicationShouldHandleReopen`) → `showMainWindow()` 切回
  `.regular` + 前置窗口.
- 显式装 `installMainMenu()` (App 菜单 + Edit 菜单) — 纯 AppKit 无 mainMenu 时 Cmd+Q
  无 terminate、文本框 Cmd+C/V/X/A/Z 标准编辑快捷键全失效.

---

## 3. Theme token (`Theme/`, `HVMTheme` namespace)

业务侧**禁止**硬编码颜色 / 字号 / 间距 / 圆角 / 边框宽度 / 动效, 一律走 `HVMTheme.<sub>.<name>`.
防漂移护栏 `scripts/check-gui-tokens.sh` (PR-L1) 扫整个 `GUI/` 拦 `Color(red:` / `Color(hex:` /
`Font.system(size:` / `padding(数字)` 硬编码. `Color(hex:)` 初始化扩展 `fileprivate` 锁在
`HVMColor.swift`, 业务侧拿不到.

| 子 namespace | token (节选) |
|---|---|
| `HVMTheme.color` | 背景 `bgBase #08090A` / `bgRaised #101113` / `bgOverlay #18191B` / `bgHover`; 文字 `textPrimary #F7F8F8` / `textSecondary` / `textTertiary` / `textOnAccent`; 边框 `borderDefault` (8% 白) / `borderEmphasis` (16%) / `borderFocus` / `borderError`; **accent `#06B6D4`** (青) / `accentHover` / `accentMuted`; 状态 `success #10B981` / `warn #F59E0B` / `error #EF4444` / `info #3B82F6`; `bgDisabled #2A2B2E` |
| `HVMTheme.font` | 严格节奏 **11/12/13/14/18/24** (不留 16/20 中间值): `xs 11` / `sm 12` / `base 13` / `md 14·medium` / `lg 18·semibold` / `xl 24·semibold`; `mono 13` / `monoSm 12` (仅 UUID/MAC/路径/命令/build 号) |
| `HVMTheme.space` | 4-pt grid: `xs 4` / `sm 8` / `md 12` / `lg 16` / `xl 24` / `xxl 32` / `xxxl 48` |
| `HVMTheme.radius` | `sm 4` (badge) / `md 6` (按钮/字段) / `lg 8` (Section) / `xl 12` (Dialog) |
| `HVMTheme.border` | `hairline 1` / `focus 2` |
| `HVMTheme.motion` | 时长 `fast 0.12` / `base 0.20` / `slow 0.32`; `easeOut` / `easeOutFast` / `easeOutSlow`; `pressSpring` (按钮 press 反馈, 业务侧不直接用) |

> accent = `#06B6D4` 是 D1 决策 (2026-05-28). `HVMTheme` namespace 用 `enum {}` + 跨文件
> extension, 避开跟老 GUI 顶层 `HVMColor` 撞名 (历史; 老 GUI 已删但 namespace 形态保留).

---

## 4. HVMUI 组件库 (`HVMUI` namespace)

`enum HVMUI {}` 作 namespace, 各组件按维度独立文件 (`Components/HVMUIButton.swift` 等),
通过 `extension HVMUI` 加 nested struct ("一组件一文件"). 用 namespace 而非顶层
`HVMButton` 的原因: 跟 `HVMTheme.*` 模式一致 + 跟 SwiftUI 自家 `Button`/`TextField` 区分.

### 交互组件 (`probeID` 必传, 见 §5)

- **`HVMUI.Button`** — 5 variant (`.primary` accent 青底 / `.secondary` 边框透明底 /
  `.ghost` 无边框 hover 出 bg / `.destructive` error 红边 / `.icon` 正方形纯图标) × 3 size
  (`.sm 24` / `.md 32` / `.lg 40`). 支持 `icon` + `iconPosition` (.leading/.trailing) /
  `isLoading` (icon 换 spinner, action 跳过) / `disabled` (opacity 0.4 保 variant 身份感) /
  `fillWidth`. hover 色变 (`easeOutFast`) + press scale 0.97 spring + Tab focus ring 渐现.
  `action` 签名 `@MainActor @Sendable () -> Void` (跟 `ProbeAction.button` 对齐).
- **`HVMUI.TextField`** — 3 size + 7 状态 (empty/filled/focused/hover/error/loading/disabled);
  `icon` / `suffix` / `errorMessage` / `disabled` / `isLoading`. 共享 `FieldChrome` modifier.
- **`HVMUI.SecureField`** — 同 TextField + `showToggle` (明文/密文切换).
- **`HVMUI.Toggle`** / **`HVMUI.Checkbox`** — 3 size + spring 切换; Checkbox 支持
  `indeterminate` 半选态; disabled 用 `bgDisabled` token 不走整体降透.
- **`HVMUI.Select<Value: Hashable>`** — 自绘下拉 (不用 SwiftUI `.popover` / `Picker`);
  generic value + `searchable` (搜索) + 键盘 ↑↓Enter 导航 + 互斥打开 + `isLoading` /
  `errorMessage` / `disabled`. `SelectOption(value:label:hint:icon:)`.

### 非交互组件 (不需 probeID)

- **`HVMUI.Section`** — 业务页骨架基石. `Section(title?, description?, variant: .default/.elevated,
  headerTrailing:?, content:, footer:?)`. footer 区自动加 Divider 隔开. default = `bgRaised` +
  轻 shadow; elevated = `bgOverlay` + 重 shadow (Dialog/popover 卡片风).
- **`HVMUI.Divider`** (h/v) / **`HVMUI.Badge`** (6 variant × 2 size, 可带 icon) /
  **`HVMUI.Icon`** (SF Symbol 包装, 5 size × 9 color) / **`HVMUI.KbdHint`** (快捷键 chip,
  typed `Key` enum) / **`HVMUI.Tooltip`** (`.hvmTooltip(...)` modifier, hover 500ms delay).

### Dialog 体系 (`Dialogs/` + `Overlay/`)

全局浮窗渲染走 `Overlay/HVMUIDialogHost.swift`:

- 根 view 套 `.hvmDialogHost()` (`DialogHostModifier`) — 内部 root-level `ZStack` 渲染
  dialog, 脱离父级 `ScrollView` clip / `Section` border / `VStack` 渲染顺序限制.
- `HVMUI.DialogPresenter` (`ObservableObject`, 注入走 `@EnvironmentObject`) 持 dialog 栈
  (支持嵌套), `present { handle in ... }` 推栈, `handle.close()` / `dismissTop()` /
  `dismissAll()` 出栈. **蒙底 `bgBase` 60% 不可点关** (X-only-close 约束, 见 §8).
- FocusTrap: dialog 显示时背景 `.disabled(true)` 让 Tab 锁卡片内. EscRouter: 渲染层
  `.onKeyPress(.escape)` 关栈顶 (没 dialog 时不拦 Esc, 透给业务).

5 个高层 dialog 走 `DialogPresenter` 的 async 便利 API (`withCheckedContinuation` 把回调转
`async`, 任何关闭路径 — 主按钮 / X / Esc / dismissAll — 都 resume, 防 await 卡死):

| API | 返回 | 说明 |
|---|---|---|
| `await dialog.alert(level:.info/.warn/.error/.success, title:message:hint?:probeID:)` | `Void` | 单按钮提示, 无取消语义 |
| `await dialog.confirm(title:message:confirmLabel:cancelLabel:destructive:probeID:)` | `.confirmed` / `.cancelled` | `destructive:true` 主按钮红边红字 |
| `await dialog.input(title:fields:[InputField]:validate?:confirmLabel:probeID:)` | `.submitted([String])` / `.cancelled` | 单/多字段, `InputField(label:placeholder:initialText:icon:secure:)`, 支持 `validate` |
| `await dialog.wizard(title:steps:[WizardStep]:probeID:)` | `.completed` / `.cancelled` | 多步骤 + 步骤指示器 + 上一步/下一步 |
| `NewGUIEncryptionDialog` (加密三态) | — | 见 §7, 参数化 form/running/done |

### UI 控件使用约束 (CLAUDE.md「UI 控件使用约束」)

- 下拉/单选 → `HVMUI.Select`, **禁** SwiftUI `Picker`/`Menu`.
- 按钮 → `HVMUI.Button` (五 variant 之一), **禁**裸 `Button` 无 style (list row 走 `.plain`
  纯点击除外).
- 输入框 → `HVMUI.TextField` / `HVMUI.SecureField`, **禁** SwiftUI `TextField`/`SecureField`.
- 开关 → `HVMUI.Toggle`, **禁** SwiftUI `Toggle`.
- Modal → 走 `.hvmDialogHost()` + `DialogPresenter`, **禁**业务侧自拼蒙底卡片.
- 分组卡片 → `HVMUI.Section`. 同需求复用现有组件; 不满足先扩展现有, 不新建别名/绕开自绘.

---

## 5. 强制 probeID (编译期 enforce, HDP-GUI 自动化全覆盖)

所有交互组件 `probeID: String` **必传** (非可选), 业务侧每个实例都得给唯一 id — 编译期保证
"每个可点/可输/可切控件都能被 hvm-dbg gui 自动化测".

- 影响: `Button` / `TextField` / `SecureField` / `Toggle` / `Checkbox` / `Select`.
- 不影响 (非交互): `Section` / `Divider` / `Badge` / `Icon` / `KbdHint` / `Tooltip`.
- `isDisabled` (或 `isLoading`) 时跳过 probe 注册 (防 click disabled 控件触发副作用), 但
  实例仍**必须**传 probeID (切 enable 时不丢 id).
- 命名规范 `<scene>.<role>.<element>`: 业务页例 `detail.button.start` /
  `vmlist.row.item-<vmID>`; Showcase 例 `showcase.button.primary`. 同 view 树内唯一.
- **派生 probe id** (复合控件内部自动派生, 业务侧只传 base):
  - `<select.probeID>.trigger` / `.search`
  - Dialog 系: `<dialog.probeID>.close` / `.confirm` / `.cancel` / `.field.<idx>` /
    `.prev` / `.next` / `.complete` / `.step.<idx>` (完整规范见 `docs/v3/HVM_DBG_GUI_PROTOCOL.md`).
- 业务侧 closure / binding 必须 `@MainActor @Sendable`.
- 接入: SwiftUI 控件 `.hvmProbe(id:label:action:)` (走自家 `ProbeRegistry`, **不**走
  `.accessibilityIdentifier` — macOS 14+ 不暴露给程序内 a11y 查询). server 由
  `HVM_GUI_PROBE=1` 启, hvm-dbg gui `ping`/`list`/`click`/`type`/`read`/`screenshot` 操作.

---

## 6. 数据 store (`Store/NewGUIStore.swift`)

`@MainActor @Observable final class NewGUIStore`. 不依赖老 `AppModel`, 不背
`embeddedID`/detached 窗口等历史耦合.

- **VM 控制单一来源**: 枚举/启停/删除一律走 `HVMControl` library
  (`VMCatalog.list` / `VMControl.{start,stop,kill,delete,status}`), 与 hvm-cli 共用同一门面.
  **禁止**store 再抄一份 `BundleDiscovery`+`BundleLock`+`HostLauncher` 拼装.
- **细粒度观察**: `vms` (`[VMSummary]`, displayName 升序) / `selectedID` / `lastError` /
  `unlockingIDs` / `encProgress` 走 observation; 解锁缓存 / fanout / vmOrder 用
  `@ObservationIgnored` 不驱动重绘.
- **1Hz 轮询** (`startPolling`, `.common` mode 让滚动/拖拽期间仍刷新): `refresh()` 重扫
  `VMCatalog.list()`, `if fresh != vms` 守卫 (VMSummary Equatable) 才赋值, 保帧率. 选中项被删
  → 退选第一个. timer 持 weak self, self 析构后下一 tick 自我 invalidate.
- **动作失败冒泡**: 动作 (start/stop/kill/delete/saveConfig/磁盘...) 经 `run(_:)` 包装,
  失败映射 `HVMError.userFacing` 写 `lastError: StoreError`, 完成总 `refresh()`.
  `MainLayoutView` 经 `.onChange(of: store.lastError)` 弹 `dialog.alert(level:.error)` (清空).
  `StoreError.id` 每次新建, 让相同 message 也能识别"又出错一次".
- **配置写入唯一走 `store.saveConfig(_:requireStopped:mutate:)`** (内部分流明文/加密),
  **禁**业务侧直接 `BundleIO.save`/`EncryptedConfigIO.save`. 明文走 `VMControl.saveConfig`,
  加密走 `saveConfigEncrypted` (需缓存的 `configKey`, 重密后刷 `unlockedConfigs`). 磁盘走
  `addDisk`/`resizeDisk`/`deleteDisk` (内部 `diskOp` 分流明文 / 加密). 剪贴板热改走
  `setClipboardSharing` (明文/加密分流 + running 时 IPC `clipboard.setEnabled`).
- **加密解锁缓存** (进程内, 不落盘, 不含 master KEK): `unlock(_:password:)` PBKDF2 600k 迭代
  走 `Task.detached` 不卡主线程, 缓存 `unlockedConfigs`/`unlockedSubKeys`/`unlockedPasswords`/
  `unlockedAt`; **5min 无活动 auto-lock** (`refresh` 内续命选中项 + 超 TTL `clearUnlock`).
  仅 `qemuPerfile` scheme; VZ-sparsebundle 提示暂不支持.
- **加密事务** (`encrypt`/`decrypt`/`rekey`, async): 走 `VMControl.{encryptVM,decryptVM,rekeyVM}`
  `Task.detached` (分钟级), progress 回 main append `encProgress`. 完成必 `clearUnlock(id)` +
  `refresh()` (config 明↔密变 / subkeys 换, 旧缓存失效). 失败返 error 文本走 dialog 内联 (不设
  全局 `lastError`, 避免双弹). `rekey` 不进 store.lastError.
- **QEMU 画面 fanout** (`ensureQemuFanout`/`tearDownFanout`): running VM 的 HDP 显示
  `QemuFanoutSession`, 停机/断连/删除时拆 (`onDisconnected` hook). `@ObservationIgnored`
  不驱动重绘 (画面由 fbView 自渲染).
- **自定义排序**: sidebar 拖拽重排 (`moveVM(_:before:)`) 持久化到 UserDefaults
  (`com.hellmessage.vm.newgui.vmOrder`), `applyOrder` 已记顺序在前 + 新 VM 按 displayName 接后.

---

## 7. 业务页

### 7.1 主界面两栏 (`Layout/MainLayoutView.swift`)

骨架 `VStack`: `[sidebar 240 | vline | detail] + hairline + statusbar`. 自绘固定宽 sidebar
(Linear 风, 不用 `NavigationSplitView` 免系统 vibrancy). 持 `@State store`, `.environment(store)`
下传; `.onAppear { startPolling() }` / `.onDisappear { stopPolling() }`.

- **无顶部 toolbar** (CLAUDE.md): 窗口顶部仅原生标题栏. 新建 VM = sidebar 底部全宽主按钮
  (`sidebar.button.create`); 刷新 = statusbar 右侧工具图标 (`statusbar.button.refresh`,
  1Hz 自动刷新, 手动为兜底).
- **statusbar**: 左侧 "N 台 VM · M 运行中" (running > 0 用 success 色), 右侧刷新图标.
- **sidebar** (`NewGUISidebarView`): 行 = 运行态圆点 + displayName + 加密 `lock.fill` 图标 +
  guestOS badge; 选中行 `bgHover` + 左侧 2px accent 竖条. 点击选中
  (`vmlist.row.item-<vmID>`), 右键 context menu (启停/删除), 拖拽重排 (`.draggable` +
  `.dropDestination`). 空态显 "还没有虚拟机".

### 7.2 详情页 inline 编辑 (`Layout/DetailOverviewView.swift` + `Detail*Section.swift`)

`DetailOverviewView` 固定头部 (标题 + badges + 启停/删除/解锁/锁定按钮) + 滚动配置区. running
时头部下加「画面 / 配置」TAB (`detail.tab.screen`/`detail.tab.config`), 画面 tab 嵌
`QemuFramebufferView` (HDP framebuffer), 否则滚动配置. **加密 VM 锁定前 `vm.config == nil`**,
section 不渲染 (仅显概览兜底 + 解锁/删除按钮).

各 inline section (文件 `Detail<X>Section.swift`):

| Section | probeID 前缀 | 写入模式 / gating |
|---|---|---|
| 概览 (只读) | — | ID(mono)/引擎/CPU/内存/主盘; 加密未解锁显 🔒 兜底 |
| 资源 (CPU/内存) | `detail.field.{cpu,memory}` | **draft + 统一保存**: 与网络共用 `draftCPU/draftMemGiB/draftNetworks`, dirty 才显放弃/保存 (`detail.button.{discard,save}`), 一次 `saveForm` 全写 |
| 网络 (NIC) | `detail.network.<i>.*` | 同上 draft; NIC 行展开编辑 (模式/设备/MAC/桥接); `editable = runState==.stopped` |
| 磁盘 | `detail.disk.{add,resize-<path>,delete-<path>}` | **即时动作** (不进 draft): 增删/扩容直接调 store; 仅 stopped |
| ISO & 启动 | `detail.boot.*` | 即时动作 (字段相互耦合, 不走 draft); macOS guest 不渲染 (走 IPSW) |
| 共享目录 | `detail.sharing.*` | 即时动作; 仅 `engine==.qemu` + `guestOS != .macOS`; 需停机 (chardev 不热挂) |
| 选项 | `detail.options.{clipboard,macStyle}` | 即时; 剪贴板 + macStyle `requireStopped=false` 可 running 热改 |
| vmnet daemon | `detail.vmnet.{install,restart,uninstall}` | 仅有 vmnet NIC 时显; 走 `VMnetSupervisor` osascript admin |
| 加密 | `detail.encryption.{encrypt,rekey,decrypt}` | 沉底; 见 §7.3 |

要点:

- **requireStopped 分级**: 多数字段 (CPU/内存/网络/磁盘/ISO/共享目录) `requireStopped=true`
  (running 改抛 `.busy`, UI 也 disabled); 剪贴板 + macStyleShortcuts `requireStopped=false`.
- **动作读 live `store.selected`**: detail 按钮动作 + toggle/binding getter 一律读
  `store.selected?.config?.<字段>`, **不**捕获渲染时 vm/cfg 快照 — `.hvmProbe` onAppear 只注册
  一次, view 复用不重注册, 捕获快照会让 hvm-dbg gui 二次 click 撞旧 VM/读旧值 (真人点击无此问题).
- **draft 守卫**: `syncDraftIfNeeded` 仅选中 VM 真变 / config 由无到有 (解锁) 才 reset draft,
  防 1Hz 刷新误清未保存编辑.

VM 动作 dialog 流程集中在 `Layout/VMActions.swift` (sidebar context menu + detail 按钮共用):
启动加密 VM `start` (已解锁复用缓存密码, 否则弹密码 input) / `unlock` / `confirmKill` /
`addDisk`/`resizeDisk`/`confirmDeleteDisk` / `confirmDelete`.

### 7.3 加密 / 解密 / rekey dialog

入口 `DetailEncryptionSection` (详情页最底). 按 VM 加密态显不同入口 (仅 stopped 可点,
动作读 `store.selected` 防 stale):

- 明文 + QEMU + 非 macOS → [加密 VM…] (`detail.encryption.encrypt`)
- 加密 `qemuPerfile` → [改密…] (`.rekey`) + [解密…] (`.decrypt`)
- 加密 `vzSparsebundle` → 灰显 "GUI 暂未接入走 hvm-cli"
- macOS guest / VZ 明文 → 灰显 "不支持整盘加密"

事务走单参数化三态 dialog `NewGUIEncryptionDialog` (mode: encrypt/decrypt/rekey),
共享 card/header chrome, 只 form 字段 + 文案按 mode 分:

- **三态 `form → running → done`**: form 收密码 + 校验 + 警告; running 显 spinner +
  `encProgress` 日志 + "请勿关闭"; done 显 ✔ + (tpmReset 时) TPM 红字.
- **running 态 `closeAction=nil` (X 不显) + 无任何按钮** — 加密事务不可中断 (X-only-close).
  hvm-dbg gui 验证: running 态 probe 列表为空 = 生效.
- **store 显式传入** (非 `@Environment`): `.hvmDialogHost()` 在 `.environment(store)` 外层,
  dialog overlay 拿不到 store 环境 → `present { handle in NewGUIEncryptionDialog(..., store: store) }`.
- **Win guest 加密/改密重置 TPM** (来自 Operation Result, 不猜): form + done 红字预警
  (BitLocker recovery key 失效). 解密无 TPM 重置. 解密/改密不要求先解锁 (dialog 自收密码).
- probeID: `dialog.{encrypt,decrypt,rekey}.{close,cancel,confirm,done}` /
  `.field.{password,confirm,old,new}`.

---

## 8. 破坏性二次确认 + X-only-close + 加密解锁

- **破坏性操作必须二次确认** (硬约束): 删除 VM / 删除磁盘 / 删除网卡 / 删除共享目录 /
  强制停止(kill) / 解密 / 重置 等任何不可逆或丢数据动作, 必先弹 `dialog.confirm(destructive: true)`
  (主按钮红边红字), 用户确认才执行. **禁止**破坏性按钮直接触发. 现状落点: `VMActions.confirmDelete` /
  `confirmKill` / `confirmDeleteDisk`, sidebar context menu "删除" `role: .destructive`,
  共享目录/网卡删除走对应 section 的 confirm.
- **X-only-close**: 弹窗只能点右上角 X 关闭 (或对应取消按钮), 蒙底 `bgBase` 60% 不可点关
  (`DialogHostModifier` 蒙底无点击手势). 不可中断流程 (加密事务 running 态) 直接隐藏 X
  (`closeAction = nil` 语义).
- **加密 VM 解锁**: 锁定态 `vm.config == nil`, 详情页 section 不渲染 (仅显概览兜底 +
  解锁/删除). 解锁走 `VMActions.unlock` → 密码 input dialog → `store.unlock` (PBKDF2 600k
  detached, 缓存 subkeys/config/password, 5min auto-lock). 解锁后 section 才出; 已解锁显
  [锁定] 按钮 (`detail.button.lock`). 启动加密 VM 走 `VMActions.start` (已解锁复用缓存密码,
  否则弹密码), **不**直接调 `store.start` 不传 password.
- **错误对话框统一走 `dialog.alert`**, 禁用 `NSAlert`. 全局错误经 `store.lastError` →
  `main.alert.error`.

---

## 附: 关键源文件索引

| 路径 | 职责 |
|---|---|
| `app/Sources/HVM/main.swift` | GUI 模式 → `NewGUIAppLauncher.run()` |
| `app/Sources/HVM/GUI/NewGUIApp.swift` | AppKit delegate + 窗口/tray/菜单 + Showcase |
| `app/Sources/HVM/GUI/Theme/HVM{Color,Font,Space,Radius,Border,Motion,Theme}.swift` | Theme token |
| `app/Sources/HVM/GUI/HVMUI.swift` | `HVMUI` namespace |
| `app/Sources/HVM/GUI/Components/HVMUI*.swift` | Button/TextField/SecureField/Toggle/Checkbox/Select/Section/Divider/Badge/Icon/KbdHint/Tooltip + ScrollerHider |
| `app/Sources/HVM/GUI/Dialogs/HVMUI{Alert,Confirm,Input,Wizard}Dialog.swift` | 4 高层 dialog async API |
| `app/Sources/HVM/GUI/Dialogs/NewGUIEncryptionDialog.swift` | 加密三态 dialog |
| `app/Sources/HVM/GUI/Overlay/HVMUIDialogHost.swift` | `DialogPresenter` + `.hvmDialogHost()` |
| `app/Sources/HVM/GUI/Store/NewGUIStore.swift` | `@Observable` 数据 store |
| `app/Sources/HVM/GUI/Layout/MainLayoutView.swift` | 主界面两栏骨架 + statusbar |
| `app/Sources/HVM/GUI/Layout/NewGUISidebarView.swift` | VM 列表 sidebar |
| `app/Sources/HVM/GUI/Layout/DetailOverviewView.swift` | 详情页头部 + 滚动配置区 |
| `app/Sources/HVM/GUI/Layout/Detail{Network,Sharing,Options,Boot,Encryption,VmnetDaemon}Section.swift` | inline 编辑 section |
| `app/Sources/HVM/GUI/Layout/VMActions.swift` | sidebar/detail 共用 VM 动作 + dialog 流程 |
| `app/Sources/HVM/GUI/Display/Qemu{FramebufferView,FanoutSession}.swift` | QEMU 画面嵌入 |
