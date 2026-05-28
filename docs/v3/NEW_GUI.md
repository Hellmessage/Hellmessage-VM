# 新 GUI 重构 — Linear 风 + 自绘 Dialog + 全局 Theme

> 状态: **实现中** 2026-05-28 (D1 已决, PR-T1 + T2 进行中)
>
> 入口已就绪 (commit b9e969d): `app/Sources/HVM/GUI/NewGUIApp.swift` + Makefile `GUI ?= new` 透传 `-Xswiftc -DNEW_GUI`. 老 GUI (`app/Sources/HVM/UI/**`) 一行不动作为回退. 本稿覆盖**基础设施层**: Theme token / Components / Dialog 框架. **业务页 (VM 列表 / 详情页 / 创建向导等) 不在本稿范围**, 后续每业务页单独立 `docs/v3/NEW_GUI_<XXX>.md` 子提案.

## 目标

- **解决问题**: 老 GUI (`app/Sources/HVM/UI/**`) 在迭代中累积了视觉漂移 (HVMColor / HVMFormSelect 等自绘组件 + 部分系统 NSAlert 混用), CLAUDE.md "UI 控件使用约束" 是事后追加的护栏. 新 GUI 想从一开始就**强约束 token + 强约束自绘**, 不留漂移空间
- **交付**: 一套 SwiftUI 基础设施, 任何后续业务页只需组合 `HVMButton` / `HVMTextField` / `HVMDialog.confirm(...)` 等, 不直接写 `Color(...)` / `Font.system(...)` / `Button {}` / `NSAlert`
- **范围 (本稿)**:
  - Theme token 系统 (颜色 / 字号 / 字重 / 间距 / 圆角 / 边框 / 动效时长)
  - 基础组件: Button / TextField / SecureField / Toggle / Select / Checkbox / Section card / Divider / Tooltip / Badge / KbdHint
  - 对话框框架: Modal 容器 / Alert (info/warn/error/success) / Confirm / Input (单字段+多字段) / Wizard (多步骤)
  - 全局 overlay 系统 (单一 dialog 上下文, z-order / focus / esc 关闭硬约束)
  - hvm-dbg gui 探针接入 (新组件 ProbeRegistry id 命名规范)
- **范围外 (本稿不做, 后续子稿处理)**:
  - 主窗口骨架 (sidebar + detail 两栏布局) — 留 PR 占位入口, 内容空
  - VM 列表 / 详情页 / 创建向导 / 加密 dialog / 文件传输 dialog / 网络配置 dialog 等所有业务面 — 一概不接, 留给后续子稿
  - 主题切换 (深/浅) — Linear 风固定深色, 不留浅色 token 通道
  - 多语言 (i18n) — 跟老 GUI 一样硬中文, 不引 LocalizedStringKey 框架
  - 动效编排 (页面切换/拖拽过场) — 仅做组件级 hover/focus 200ms ease-out, 不做高级动效系统
  - 国际化文件选择 / 系统通知 / 系统菜单栏 — 沿用老 GUI 的 AppKit 入口 (`HVMAppDelegate` 复用模板; 业务接入子稿处理)

## 项目当前状态 (设计前提)

```
✅ 已有 (新 GUI 可立即基于):
  app/Sources/HVM/GUI/NewGUIApp.swift                          (NSApp + 单窗口入口占位)
  app/Sources/HVM/main.swift                                    (#if NEW_GUI 分流, 默认开)
  Makefile `GUI ?= new` 开关 + `make dev-open` 3s 增量循环
  HVM_GUI_PROBE=1 ProbeServer (HDP-GUI), hvm-dbg gui {ping,list,click,type,read,screenshot}
  HVMCore / HVMBundle / HVMNet / HVMStorage / HVMQemu / HVMDisplayQemu (后端 service 层全部就绪, 与 GUI 解耦)
  老 GUI (app/Sources/HVM/UI/**) 整套保留作回退, GUI=old 仍能正常构建运行

❌ 缺失 (本稿要补):
  app/Sources/HVM/GUI/Theme/                                    (token 文件)
  app/Sources/HVM/GUI/Components/                               (Button / TextField / 等)
  app/Sources/HVM/GUI/Dialogs/                                  (Modal / Alert / Confirm / Input / Wizard)
  app/Sources/HVM/GUI/Overlay/                                  (全局 DialogHost / FocusTrap / EscRouter)
  app/Sources/HVM/GUI/Probe/                                    (hvmProbe modifier 适配新组件)
  docs/v1/NEW_GUI.md                                            (现状描述, 本稿合入后回写)
```

**核心洞察**: 新 GUI 是**纯 SwiftUI** (老 GUI 是 SwiftUI on top of AppKit + 大量 NSWindow / NSPopover / NSAlert 混用). 新 GUI 把 AppKit 局限在 `NewGUIAppDelegate` + 主 `NSWindow` 两处, 其余全部 SwiftUI. Dialog 系统不调任何 `.alert` / `.confirmationDialog` / `.sheet` 系统 modifier, 全走自家 `DialogHost` overlay.

## 选型对比

### 视觉风格基调

| 风格 | 主底 | 圆角 | 字号节奏 | accent | 实现成本 | 备注 |
|---|---|---|---|---|---|---|
| **C. Linear 风** ✅ 选定 | `#08090A` (极深, 偏蓝调) | 6 / 8 / 12 | 11/12/13/14/18/24 严格 | HVM 自家青 `#06B6D4` (避免撞 Linear 蓝紫) | 中-高 | 工具型 SaaS 感, 信息密度可控 |
| A. 老 GUI 深灰 | `#18181B` (中性灰) | 6 / 8 | 12/13/14/16/24/32 宽松 | 老 GUI 自定 | 低 | 跟老的视觉一样, 不算真重构 |
| B. Raycast 风 | 浮动卡片 + 大圆角 12-16 | — | 13/14/16 | 单橙红 | 中 | 命令栏场景, HVM 长驻不合适 |
| D. macOS vibrancy | NSVisualEffectView | 4-6 系统标准 | SF Pro 系统默认 | 系统强调色 | 低 | 失辨识度, 跟 UTM/Parallels 撞型 |

**选定 C**. 用户 2026-05-28 拍板. accent 用青 `#06B6D4` 区分 Linear 蓝紫. 其他 token (字号节奏严格 / 4-pt grid spacing / 1px 边框 / stroke icon) 全照 Linear 思路.

### Dialog 系统底层

| 方案 | 实现 | 评价 |
|---|---|---|
| **A. 全局 DialogHost overlay (单 ZStack 顶层)** ✅ 选定 | 主窗口根 view 套一个 `DialogHost { content }`, 内部 `@Environment(\.dialogPresenter)` 给业务 layer 调; Dialog 显示走 SwiftUI ZStack overlay, 蒙底 `Color.black.opacity(0.5)` + 中心卡片; esc / 右上 X 关 | 单一 z-order 上下文, 多 Dialog 排队/堆叠都自家管; 完全脱离 NSPanel / NSPopover; SwiftUI focus / animation 完整 |
| B. NSPanel 自绘 | 每个 Dialog 一个独立 NSPanel sheet attach 到主窗口 | 接 AppKit 内嵌 SwiftUI hostingView, z-order / focus / 动效要自己处理两层 (NSPanel + SwiftUI) 互相打架 |
| C. SwiftUI `.sheet` / `.alert` | 系统 modifier | 不能完全自绘 (系统会强行加自家 padding / button style), 跟用户约束"自绘不要系统"冲突 |

**选定 A**. 完全 SwiftUI, z-order 单源管理, 动效全自家控. 实现细节见下「Dialog 框架」节.

### Theme token 形态

| 形态 | 形式 | 优势 | 劣势 |
|---|---|---|---|
| **A. 静态 enum + 顶层 struct (Linear 同款)** ✅ 选定 | `enum HVMTheme { static let bgBase = Color(...) }`, 业务直接 `HVMTheme.bgBase` | 编译期检查 typo / 不存在的 token 直接报错; 无运行时分发 | 不支持运行时切换 (我们也不需要) |
| B. EnvironmentValue 注入 (Apple HIG 风) | `@Environment(\.hvmTheme) var theme` | 支持深浅模式 / A/B 主题切换 / preview override | 业务每处都要 `@Environment`, 单深色场景过度工程 |
| C. JSON 配置外置 | token 写 `theme.json`, 加载时解析 | 设计师可改 | 加 JSON 解析 + 类型不安全 + 单深色无需 |

**选定 A**. 与"固定深色无切换"目标完全契合. token 改值时编译期一次性扩散, 不会出现"某处忘改"漂移.

## 实现要点

### 目录结构

```
app/Sources/HVM/GUI/
├── NewGUIApp.swift                    (已存在; 入口 NSApp + NSWindow shell)
├── Theme/                             (★ 本稿新增)
│   ├── HVMTheme.swift                 (top-level: HVMTheme.color / .font / .space / .radius / .border / .motion)
│   ├── HVMColor.swift                 (色板枚举)
│   ├── HVMFont.swift                  (字号 + 字重 + family)
│   ├── HVMSpace.swift                 (4-pt grid)
│   ├── HVMRadius.swift                (圆角档位)
│   ├── HVMBorder.swift                (边框宽 + 颜色)
│   └── HVMMotion.swift                (动效时长 + 曲线)
├── Components/                        (★ 本稿新增)
│   ├── HVMButton.swift                (5 种 variant: primary / secondary / ghost / destructive / icon)
│   ├── HVMTextField.swift             (普通 + 带 placeholder + 带后缀图标 + error 态)
│   ├── HVMSecureField.swift           (密码用; show/hide 切换)
│   ├── HVMToggle.swift                (滑块开关)
│   ├── HVMCheckbox.swift              (方框勾选)
│   ├── HVMSelect.swift                (下拉; 支持搜索 + 键盘导航)
│   ├── HVMSection.swift               (卡片容器; title + content + 可选 footer)
│   ├── HVMDivider.swift               (1px hairline 分隔线, 颜色 token 化)
│   ├── HVMBadge.swift                 (状态徽标; running / stopped / error 等)
│   ├── HVMTooltip.swift               (.hvmTooltip("...") modifier; 500ms 延迟出)
│   ├── HVMKbdHint.swift               (键盘快捷键提示 chip, "⌘+S" 之类)
│   └── HVMIcon.swift                  (stroke icon 包装; 默认走 SF Symbols, weight=.medium)
├── Dialogs/                           (★ 本稿新增)
│   ├── HVMDialog.swift                (顶级入口: HVMDialog.alert(...) / .confirm(...) / .input(...) / .wizard(...))
│   ├── HVMModal.swift                 (Modal 容器: 顶栏标题 + X + content + 可选 footer)
│   ├── HVMAlertDialog.swift           (info / warn / error / success 四档, icon + title + message + 主按钮)
│   ├── HVMConfirmDialog.swift         (title + message + 主/副按钮; destructive 主按钮变红)
│   ├── HVMInputDialog.swift           (单字段 / 多字段表单; 内置 validation hook)
│   └── HVMWizardDialog.swift          (多步骤: 步骤指示器 + 上一步/下一步/取消 + 每步是个 View)
├── Overlay/                           (★ 本稿新增)
│   ├── DialogHost.swift               (根 view modifier; 内含 z-order 管理 + 蒙底 + esc 路由)
│   ├── DialogPresenter.swift          (presenter 协议 + EnvironmentValue 注入)
│   ├── FocusTrap.swift                (Dialog 开时锁 focus 在卡片内, tab/shift+tab 不跑出去)
│   └── EscRouter.swift                (esc 优先关栈顶 Dialog, 没 Dialog 时透给业务 view)
└── Probe/                             (★ 本稿新增)
    └── HVMProbeID.swift               (新组件的 .hvmProbe(id:label:action:) 命名规范文档化)
```

**单文件 ≤ 300 行原则**: token 按维度拆 (色 / 字 / 间距分别独立), 组件一个文件一个 widget. Dialog 系统因关联紧密, `HVMDialog.swift` 是 entry hub, 其它按种类拆.

### Theme token 字段定义

(关键 token 列出, 完整清单 PR-T1 落代码)

```swift
// HVMColor.swift
enum HVMColor {
    // 背景层 (z 从深到浅)
    static let bgBase     = Color(hex: 0x08090A)   // 主底, 极深偏蓝
    static let bgRaised   = Color(hex: 0x101113)   // 卡片底 (1 级抬升)
    static let bgOverlay  = Color(hex: 0x18191B)   // Dialog 卡片 (2 级抬升)
    static let bgHover    = Color(hex: 0xFFFFFF, alpha: 0.04)   // hover 叠加层

    // 文字
    static let textPrimary   = Color(hex: 0xF7F8F8)   // 主文字, 接近白
    static let textSecondary = Color(hex: 0x8A8F98)   // 次要文字 (描述 / hint)
    static let textTertiary  = Color(hex: 0x62666D)   // 弱化文字 (placeholder / disabled)
    static let textOnAccent  = Color(hex: 0x0A0A0A)   // accent 底上的文字 (青底配深字)

    // 边框
    static let borderDefault = Color(hex: 0xFFFFFF, alpha: 0.08)
    static let borderFocus   = Color(hex: 0x06B6D4, alpha: 0.6)   // accent focus ring
    static let borderError   = Color(hex: 0xEF4444, alpha: 0.6)

    // 强调色 (青 — 替代 Linear 蓝紫, 避免撞型)
    static let accent        = Color(hex: 0x06B6D4)
    static let accentHover   = Color(hex: 0x0891B2)
    static let accentMuted   = Color(hex: 0x06B6D4, alpha: 0.15)

    // 状态色 (沿用通用 web design 色相)
    static let success = Color(hex: 0x10B981)
    static let warn    = Color(hex: 0xF59E0B)
    static let error   = Color(hex: 0xEF4444)
    static let info    = Color(hex: 0x3B82F6)
}

// HVMFont.swift
enum HVMFont {
    // 字号 (严格节奏, 禁止中间值)
    static let xs   = Font.system(size: 11, weight: .regular)   // 标签 / kbd hint
    static let sm   = Font.system(size: 12, weight: .regular)   // 次要文字
    static let base = Font.system(size: 13, weight: .regular)   // 正文
    static let md   = Font.system(size: 14, weight: .medium)    // 按钮 / 字段 label
    static let lg   = Font.system(size: 18, weight: .semibold)  // 区块标题
    static let xl   = Font.system(size: 24, weight: .semibold)  // 页面标题

    // mono (仅 UUID / MAC / 路径 / shell 命令; CLAUDE.md 已约束)
    static let mono     = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let monoSm   = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// HVMSpace.swift — 4-pt grid (Linear 同款)
enum HVMSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

// HVMRadius.swift
enum HVMRadius {
    static let sm: CGFloat = 4    // 小按钮 / badge
    static let md: CGFloat = 6    // 普通按钮 / 字段 / 卡片
    static let lg: CGFloat = 8    // Section card
    static let xl: CGFloat = 12   // Dialog 卡片
}

// HVMBorder.swift
enum HVMBorder {
    static let hairline: CGFloat = 1     // 默认细边
    static let focus: CGFloat = 2        // focus ring
}

// HVMMotion.swift
enum HVMMotion {
    static let fast: Double = 0.12       // hover / press
    static let base: Double = 0.20       // 字段 focus / Dialog 进出
    static let slow: Double = 0.32       // 切页 / Wizard 步骤

    static let easeOut = Animation.easeOut(duration: base)
    static let easeIn  = Animation.easeIn(duration: base)
    static let spring  = Animation.spring(response: 0.3, dampingFraction: 0.85)   // 慎用, 仅按钮 press 反馈
}

// HVMTheme.swift — 顶层聚合, 业务侧只 import 这一个
enum HVMTheme {
    typealias color  = HVMColor
    typealias font   = HVMFont
    typealias space  = HVMSpace
    typealias radius = HVMRadius
    typealias border = HVMBorder
    typealias motion = HVMMotion
}
```

**用法**: 业务侧一律 `HVMTheme.color.bgBase`, **禁止** `Color(red:...)` / `Color(hex:...)` 散落. 防漂移护栏 PR-T6 加 lint script `scripts/check-gui-tokens.sh` (grep `app/Sources/HVM/GUI/` 内除 `Theme/` 外, 出现 `Color(red:` / `Font.system(size:` / 硬编码数字 padding 报错).

### 组件 API 形态 (统一签名约束)

**Button**

```swift
HVMButton("保存", variant: .primary) { /* action */ }
HVMButton("删除", variant: .destructive, icon: .trash) { ... }
HVMButton(icon: .gear, variant: .ghost) { ... }                  // 仅 icon

// variant 5 种 (互斥):
// .primary       — accent 青底, 主操作
// .secondary     — 边框 + 透明底, 次要操作
// .ghost         — 无边框, 仅 hover 出 bg, 弱化操作
// .destructive   — 边框 + 红字, 危险操作 (确认前)
// .icon          — 纯图标按钮 (Dialog 关闭 X / toolbar icon)
```

**TextField** 

```swift
HVMTextField("名称", text: $name, placeholder: "我的 VM")
HVMTextField("CPU", text: $cpu, suffix: "核", validation: { Int($0) != nil && Int($0)! >= 1 })
HVMSecureField("密码", text: $pwd, showToggle: true)
```

**Select** (下拉)

```swift
HVMSelect("引擎", selection: $engine, options: [
    .init(value: .vz,   label: "VZ (推荐)"),
    .init(value: .qemu, label: "QEMU (Windows)")
])
HVMSelect("ISO", selection: $iso, options: isoList, searchable: true)
```

**Section card**

```swift
HVMSection("基本信息") {
    HVMTextField("名称", text: $name)
    HVMSelect("引擎", selection: $engine, options: ...)
} footer: {
    HVMButton("保存", variant: .primary) { save() }
}
```

(完整组件清单 + 每个的 variant / parameters 在 PR-C1 ~ PR-C8 各 PR 内确定)

### Dialog 框架 — DialogHost overlay 设计

**根接入** (`NewGUIApp.swift` 改 1 处):

```swift
let host = NSHostingController(rootView:
    NewGUIRootView()
        .dialogHost()                  // ★ 新增: 注入 DialogHost
)
```

**Presenter 接口**:

```swift
@Environment(\.dialogPresenter) var dialog

// 业务侧调用:
Task { @MainActor in
    let result = await dialog.confirm(
        title: "删除 VM?",
        message: "VM \"\(name)\" 的所有数据将被删除. 不可恢复.",
        confirmLabel: "删除",
        cancelLabel: "取消",
        destructive: true
    )
    if result == .confirmed { deleteVM() }
}

// 输入:
let pwd = await dialog.input(
    title: "解锁加密 VM",
    fields: [.init(label: "密码", binding: $pwd, secure: true)]
)

// 信息 / 警告 / 错误 / 成功:
await dialog.alert(level: .error, title: "启动失败", message: errorMsg, hint: "检查 daemon 是否运行")

// Wizard:
await dialog.wizard(
    title: "创建 VM",
    steps: [
        WizardStep(title: "选 OS") { WizardChooseOSView() },
        WizardStep(title: "配置") { WizardConfigView() },
        WizardStep(title: "确认") { WizardReviewView() }
    ]
)
```

**z-order 约束** (硬规则, DialogHost 内部强制):
- 同时只允许 1 个 Dialog 可见 (新 Dialog 进栈把旧的压底, esc / 关闭按钮先关栈顶)
- 蒙底 `Color.black.opacity(0.5)` 不可点关 (CLAUDE.md GUI 约束沿用)
- 关闭只能: 右上 X / esc / 主按钮 / cancel 按钮 / `closeAction = nil` 时全部禁
- Dialog 进出动效: 200ms ease-out fade + scale 0.98 → 1.0
- focus trap: Dialog 开时 tab 循环锁卡片内, Dialog 关时还焦点给上一个 first responder

**异步 API 模式** (async/await 不用 callback):
- 所有 Dialog presenter 方法 `async`, 内部 await SwiftUI overlay close
- 长事务 Dialog (运行中 closeAction = nil) 走 `dialog.present(...)` 拿 handle, 业务自管 close
- 取消用 `Task.cancellation` 透传, Dialog 内监听到 cancel 自动消失

**HDP-GUI probe 接入**: 每个 Dialog 内的关键控件 (主按钮 / 取消按钮 / 输入框) 必须有 `.hvmProbe(id: "dialog.<name>.<role>.<element>", ...)`. 命名规范:
```
dialog.confirm.button.confirm
dialog.confirm.button.cancel
dialog.input.field.<fieldName>
dialog.wizard.button.next
dialog.wizard.button.prev
dialog.wizard.step.<index>      (步骤指示器点击, 仅前进 step 可点)
```

### 老 GUI 老 dialog 不动

- 老 `ErrorDialog` / `EncryptionPasswordDialog` / `CreateVMDialog` 等留在 `app/Sources/HVM/UI/Dialogs/`, 仅 `GUI=old` 路径用
- 新 GUI 从零写, 不 import 老的; 老 dialog 类型不引为参考 (设计稿留底)
- 新老共存期 (本稿 PR 全部合入后到业务页迁移完): 用户主力跑 `GUI=new`, 用 `GUI=old` 跑日常 VM 任务. 互不污染

## 风险与待验证

### P0 (必须 gate, 阻塞合入)

- **P0-1: SwiftUI 全局 overlay 在 macOS 14 上 focus / esc 路由的可靠性**
  - 实现 DialogHost 后必须做 e2e: hvm-dbg gui 开 confirm → 按 esc → Dialog 关 + 焦点回上一个 field
  - 多 Dialog 堆叠 (Wizard 内再开 confirm "你确定取消?") 时 esc 只关栈顶
  - **验证**: PR-D1 合入后跑 `hvm-dbg gui` 自动化覆盖 ≥ 5 个交互序列
- **P0-2: hover/focus 动效在 release 模式 60fps**
  - 老 GUI 在某些机型有 SwiftUI 重 render 卡顿. 新 GUI 用 `.animation(HVMMotion.easeOut)` 必须实测 release `make open` (不是 dev-open) 下流畅
  - **验证**: PR-C1 第一个 HVMButton 合入后 5 个并排 button 同时 hover 截视频
- **P0-3: lint script 防 token 漂移**
  - `scripts/check-gui-tokens.sh` 必须捕获 `Color(red:` / `Font.system(size:` / `padding(8)` 硬数字
  - **验证**: PR-T6 落 script 后, 故意在 GUI/Components/HVMButton.swift 加一行 `Color(red: 1, green: 0, blue: 0)`, script 必须报错

### P1 (合入前知会, 不阻塞)

- SwiftUI 6 的 `@Observable` 在 Dialog presenter 上跟 `@Environment` 配合的最佳实践待踩 (备选 `@State` 容器 + EnvironmentObject 老套路, 牺牲细粒度 update)
- focus trap 用 SwiftUI 原生 `.focusable() + .focused($field)` vs 自家 NSResponderChain 拦截 — PR-D2 验后定
- Wizard 内的步骤切换动效 (左滑/右滑) 优先级低, 第一版直接 fade, v1.1 加滑动

### P2 (留待业务页迁移期再回头)

- 暗色 token 已在用户系统全局生效 (macOS Tahoe 用户某些情况下 .darkAqua 跟系统 vibrancy 联动) 时, 我们的 `Color(hex: 0x08090A)` 渲染色偏 — 不计在本稿范围, 监控用户反馈
- 用户屏幕 P3 色域下 accent 青 `#06B6D4` 偏鲜艳 — 不计入本稿
- VoiceOver / 系统辅助功能适配 — 老 GUI 没做, 新 GUI 先不做, 留 v2

## PR 拆解

每个 PR ≤ 2 天工作量 (CLAUDE.md "开发流程约束"). 全部走 `GUI=new` 路径, 老 GUI 一行不动.

**Phase T — Theme 基础 (本周)**

| PR | 标题 | 验收 |
|---|---|---|
| **T1** | feat(gui): Theme 6 个 token 文件 (Color/Font/Space/Radius/Border/Motion) + HVMTheme 聚合 | NewGUIRootView 切到全 token, 视觉跟现状一致; `make build GUI=new` 通过; `hvm-dbg gui screenshot` 截图无回归 |
| **T2** | feat(gui): NewGUIRootView 重做欢迎页 (用 T1 token 演示色 / 字 / spacing) | 截图 review 通过; 验证窗口 1080×720 锁死不缩 |

**Phase C — 基础组件 (1.5 周)**

| PR | 标题 | 验收 |
|---|---|---|
| **C1** | feat(gui): HVMButton 5 variant + hover/press/disabled 状态 + .hvmProbe 接入 | 5 个 variant 并排 demo, hvm-dbg gui click 触发 action OK |
| **C2** | feat(gui): HVMTextField + HVMSecureField + 错误 / 验证态 | 输入字段 demo, hvm-dbg gui type 透字 OK |
| **C3** | feat(gui): HVMToggle + HVMCheckbox | 开关 demo, click 切态 OK |
| **C4** | feat(gui): HVMSelect (下拉 + 搜索 + 键盘导航) | 单选 + 搜索 demo, ↑↓ enter 选中 OK |
| **C5** | feat(gui): HVMSection / HVMDivider / HVMBadge | 卡片容器 demo, 视觉一致 |
| **C6** | feat(gui): HVMTooltip + HVMKbdHint + HVMIcon | hover 500ms 出 tooltip, kbd hint chip 视觉 OK |
| **C7** | feat(gui,probe): hvm-dbg gui 探针对新组件的 id 命名规范 + ProbeRegistry 兼容 | hvm-dbg gui list 能看到新组件 id 树 |
| **C8** | docs(gui): components 走查 demo 页 (NewGUIRootView 改一个 "Components Showcase") | 自动截图存档作 visual regression 基线 |

**Phase D — Dialog 框架 (1.5 周)**

| PR | 标题 | 验收 |
|---|---|---|
| **D1** | feat(gui): DialogHost overlay + DialogPresenter + EnvironmentValue 注入 | 业务 view 能 await dialog.alert(...), 蒙底 + esc + X 关闭 OK |
| **D2** | feat(gui): FocusTrap + EscRouter (tab 锁卡片 + esc 栈顶关) | hvm-dbg gui 自动化测 multi-stack esc 路由 |
| **D3** | feat(gui): HVMAlertDialog (info/warn/error/success 四档) | 4 档 demo + hvm-dbg gui screenshot 视觉一致 |
| **D4** | feat(gui): HVMConfirmDialog (含 destructive 主按钮) | 确认/取消 / 危险确认 二态 demo + 取消按钮自动 focus |
| **D5** | feat(gui): HVMInputDialog (单字段 + 多字段表单 + validation hook) | 单/多字段 demo, validation fail 时主按钮禁用 |
| **D6** | feat(gui): HVMWizardDialog (步骤指示器 + 上下一步 + 取消) | 3 步 demo, hvm-dbg gui click next/prev 切步 OK |
| **D7** | feat(gui): Dialog probe id 命名规范固化 + 文档 | docs/v3/HVM_DBG_GUI_PROTOCOL.md 加 "Dialog probe id 规范" 节 |

**Phase L — 防漂移 (收尾, 半天)**

| PR | 标题 | 验收 |
|---|---|---|
| **L1** | chore(gui): scripts/check-gui-tokens.sh + Makefile 接入 | 故意硬编码触发, script 报错; `make check-gui` 加进 Makefile |

**合入后**:
- 回写 `docs/v1/NEW_GUI.md` 现状描述
- `CLAUDE.md` 加 "新 GUI UI 控件使用约束" 节 (跟老 GUI 那节平行, 取代旧约束)
- `docs/v3/README.md` 索引该稿标 "代码已合入"
- 后续每业务页迁移单独立 `docs/v3/NEW_GUI_<feature>.md` 子稿

## 未决事项 (Decisions)

| ID | 决策 | 默认 | 决策时机 |
|---|---|---|---|
| **D1** | accent 色到底用青 `#06B6D4` 还是橙 `#F97316`? | **已决 2026-05-28: 青 `#06B6D4`** (用户拍板, 冷感工具属性 + 跟 Linear 蓝紫明显区分) | ✅ 已决 |
| **D2** | mono 字体用 SF Mono / JetBrains Mono / 系统 default monospaced? | 系统 monospaced (零打包) | T1 PR 内决 |
| **D3** | Dialog 蒙底 `Color.black.opacity(0.5)` 还是带 blur material? | 纯黑 0.5 (Linear 同款) | D1 PR 内决 |
| **D4** | HVMSelect 搜索匹配算法: 子串 / fuzzy / 拼音首字母? | 子串 (最简, 中文友好) | C4 PR 内决 |
| **D5** | Wizard 步骤指示器位置: 顶部水平 / 左侧垂直? | 顶部水平 (Dialog 卡片宽 = 主轴) | D6 PR 内决 |
| **D6** | 业务页迁移顺序 (本稿合入后第一个业务页是哪个)? | 用户决 (建议从 VM 列表入手) | 本稿全 PR 合入后用户拍 |
| **D7** | 是否给 Dialog 加 "再次操作" 撤销提示? (例: 删除后 5s 内可撤) | 不加 v1, 留 v2 | 本稿不决, 业务页迁移时按需 |
| **D8** | 老 GUI 何时退役? | 新 GUI 全业务页迁完 (估 2-3 个月) 后, 老 UI/ 删除 | 不决, 走"业务迁完再说"路径 |

## 不在此 PR 范围 (留给后续子稿)

每业务页独立子稿, 引本稿作"基础设施前置依赖":

- `docs/v3/NEW_GUI_MAIN_LAYOUT.md` — sidebar + detail 两栏主窗口骨架 + 工具栏
- `docs/v3/NEW_GUI_VM_LIST.md` — VM 列表项 (running/stopped/encrypted 状态 / 加密锁图标 / context menu)
- `docs/v3/NEW_GUI_VM_DETAIL.md` — 详情页 (overview / sharing / network / disk / 加密 等 section)
- `docs/v3/NEW_GUI_CREATE_VM.md` — 创建 VM Wizard (复用本稿 HVMWizardDialog)
- `docs/v3/NEW_GUI_ENCRYPTION.md` — 加密 / 解密 / rekey dialog (复用 HVMInputDialog)
- `docs/v3/NEW_GUI_FILE_TRANSFER.md` — 文件传输 dialog
- `docs/v3/NEW_GUI_NETWORK.md` — 网络配置 + vmnet daemon 控制
- `docs/v3/NEW_GUI_FRAMEBUFFER.md` — VM 窗口 framebuffer 嵌入 (HDP 接入)

子稿评审独立于本稿, 但都必须在本稿合入后才动手.

---

**待用户敲定**: D1 accent 色 + 整体方向确认. 用户点头后开 PR-T1.
