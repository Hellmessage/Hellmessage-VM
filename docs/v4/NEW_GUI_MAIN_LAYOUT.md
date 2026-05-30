# 新 GUI 业务页 — 主窗口骨架 + VM 列表 (sidebar/detail 两栏)

> 状态: **设计稿** 2026-05-30
>
> 第一个业务页提案. 前置依赖: [NEW_GUI.md](NEW_GUI.md) 基础设施层 (Theme token / HVMUI 组件库 / Dialog 框架) 已全合 (Phase T/C/D ✅). 本稿把新 GUI 从「Theme/组件 Showcase」推进到「真正能管 VM 的两栏主界面」, 是后续所有业务页 (详情 / 创建向导 / 网络 / framebuffer) 挂载的脊梁.
>
> 合并了 v4 README 规划中的 `NEW_GUI_MAIN_LAYOUT.md` + `NEW_GUI_VM_LIST.md` 两项 (sidebar 本身就是 VM 列表, 拆两份会割裂). 用户 2026-05-30 拍板: 第一业务页 = 主骨架 + VM 列表, store 策略 = 为新 GUI 写**精简新 store** (不复用老 AppModel).

## 目标

- **解决问题**: 新 GUI (`app/Sources/HVM/GUI/**`) 现在只是 Theme + 组件 + Dialog 的 Showcase 演示页 (`NewGUIApp.swift` 的 `NewGUIRootView`), 不能管任何真实 VM. 要让 `make run-app` 打开后看到的是「左侧 VM 列表 + 右侧详情」的真界面, 能选中 / 启动 / 停止 / 删除 VM.
- **交付**:
  1. 一个**视图无关的共享控制层** library target `HVMControl` — 把"枚举 / 启停 / 删除 VM"这套目前散落在 3 处 (hvm-cli `ListCommand` / 老 `AppModel.refreshList` / 未来新 GUI store) 的逻辑收口到一处, CLI 与新 GUI 共用同一套后端门面, 不再各写各的
  2. 一个**精简新 store** `NewGUIStore` (`@Observable @MainActor`) — 持有 VM 列表 + 选中态, 1Hz 轮询运行态, 所有动作转发给 `HVMControl`. 不依赖老 `AppModel`, 不背 `embeddedID` / `detachedQemuVMs` / VZ in-process session 等老 GUI 历史耦合
  3. 一个**两栏主界面** `MainLayoutView` — sidebar (VM 列表, 全部用 HVMUI 组件 + Theme token) + detail (选中 VM 的最小 overview + 启停按钮) + 顶部 toolbar (新建占位 / 刷新). 替换当前 `NewGUIRootView` 成为 `make run-app` 默认页; Showcase 退到 `HVM_GUI_SHOWCASE=1` env 后保留作组件 living doc
- **范围 (本稿)**:
  - 共享控制层 `HVMControl`: `VMSummary` 值类型 + `VMCatalog.list()` 枚举 + `VMControl.{start,stop,kill,status,delete}`
  - 新 store `NewGUIStore`: list / selectedID / 1Hz poll / start / stop / kill / delete / 错误冒泡到 dialog
  - 主界面 `MainLayoutView`: 两栏布局 + toolbar + StatusBar 占位
  - sidebar VM 列表行: 运行态圆点 (running 绿 / stopped 灰) + displayName + guestOS badge + 加密锁图标 + 选中高亮 + 右键 context menu
  - detail 最小版: overview section (name / id / engine / cpu / mem / 磁盘 / 运行态) + 主操作按钮 (启动 / 停止 / 强制停止)
  - 加密 VM 列表展示 (锁图标 + "Encrypted" badge, config 为 nil 时走 routing 元数据拿 displayName/guestOS); 启动加密 VM 弹密码 InputDialog
  - probeID 全覆盖 (R6 强制), hvm-dbg gui 自动化 e2e
- **范围外 (本稿不做, 后续子稿)**:
  - **详情页完整 section** (network / disk 编辑 / sharing / 加密管理) → `NEW_GUI_VM_DETAIL.md`. 本稿 detail 只做只读 overview + 启停, 不做配置编辑
  - **创建 VM 向导** → `NEW_GUI_CREATE_VM.md`. 本稿 toolbar 的 [新建] 按钮先弹 "即将接入" alert 占位
  - **framebuffer 嵌入** (running VM 画面) → `NEW_GUI_FRAMEBUFFER.md`. 本稿启动 VM 后 detail 仍显示 overview (标 "运行中, 画面嵌入待 framebuffer 子稿"), 真画面走老 GUI / 独立窗口暂不接
  - **加密 / 解密 / rekey / clone 事务** → `NEW_GUI_ENCRYPTION.md`. 本稿只做"启动加密 VM 时弹密码", 不做加密管理
  - **vmnet daemon 安装 / 网络面板** → `NEW_GUI_NETWORK.md`
  - **拖 .hvmz 进 sidebar 临时挂载** (老 AppModel 的 `dropEphemeralBundle`) — 低频, 推后
  - **VM 重排序持久化** (老 sidebar 支持拖拽重排) — 推后, 本稿按 displayName 排序

## 项目当前状态 (设计前提)

```
✅ 已有:
  app/Sources/HVM/GUI/  Theme/ + Components/ + Dialogs/ + Overlay/   (基础设施全合)
  app/Sources/HVM/GUI/NewGUIApp.swift                                (NSWindow shell + NewGUIRootView Showcase)
  app/Sources/hvm-cli/Support/HostLauncher.swift                     (launch(bundleURL:password:) → pid; 仅 hvm-cli target)
  app/Sources/hvm-cli/Commands/{List,Start,Stop,Kill,Delete}Command  (CLI 各自实现枚举/启停/删除)
  app/Sources/HVMBundle/{BundleDiscovery,BundleLock,BundleIO}        (枚举 / flock 运行态 / config.yaml I/O)
  app/Sources/HVMEncryption/{EncryptedBundleIO,RoutingJSON,RoutingMetadata}  (加密检测 + 路由元数据)
  app/Sources/HVMIPC/{Protocol(IPCOp/IPCRequest/IPCStatusPayload),SocketClient}  (停止/状态 IPC)
  app/Sources/HVMCore/Paths.swift  HVMPaths.{vmsRoot,socketPath,...}

❌ 缺失 (本稿补):
  app/Sources/HVMControl/                       (★ 新 library target: VMSummary + VMCatalog + VMControl + 迁入 HostLauncher)
  app/Sources/HVM/GUI/Store/NewGUIStore.swift   (★ 精简新 store)
  app/Sources/HVM/GUI/Layout/MainLayoutView.swift   (★ 两栏主界面)
  app/Sources/HVM/GUI/Layout/SidebarView.swift      (★ VM 列表 sidebar)
  app/Sources/HVM/GUI/Layout/DetailOverviewView.swift  (★ detail 最小 overview)
  app/Sources/HVM/GUI/Layout/MainToolbarView.swift     (★ toolbar)
```

**核心洞察**: 枚举 + 启停 + 删除这套逻辑现在被**抄了 3 份** (ListCommand 一份, AppModel.refreshList 一份, 新 GUI 又要一份). 与其在新 store 里抄第 4 份, 不如**抽一个 library target 收口**, 让 CLI 也回头复用. 这既满足用户"新 store 不依赖老 AppModel"的诉求, 又避免"再抄一份逻辑漂移" (CLAUDE.md 修复验证约束反复强调的同模式遗漏点问题).

## 选型对比

### 选型 1: 共享控制层放哪 (新 store 怎么调后端)

| 方案 | 形态 | 优势 | 劣势 |
|---|---|---|---|
| **A. 新 library target `HVMControl`** ✅ 选定 | 新建 `app/Sources/HVMControl/`, 含 `VMSummary` / `VMCatalog.list` / `VMControl.{start,stop,kill,status,delete}`; `HostLauncher` 从 hvm-cli 迁入; hvm-cli `HVMControl` 改依赖它 (CLI 命令瘦身) | 逻辑单一来源, CLI + GUI 共用; `make build` 编译期保证两端一致; 收口 3 份重复; 加密/明文分流只写一次 | 一次性 refactor 动 hvm-cli (5 个 command 改调用); 需回归 CLI |
| B. 新 store 自抄 Process spawn + 枚举 | 在 `app/Sources/HVM/GUI/Store/` 内复制 HostLauncher 的 fork 逻辑 + 枚举逻辑 | 不动 hvm-cli, 改动局部 | 第 4 份重复; 后端行为改时 GUI 漂移 (正是 CLAUDE.md 反例教训); `HostLauncher` 在 cli target GUI import 不到, 必须复制 |
| C. 新 store 复用老 AppModel 的 spawnExternalHost | 把 AppModel 的启动逻辑提取成函数给新 store 调 | 不新增 target | 用户明确否决"依赖老 AppModel"; AppModel 启动路径跟 VZ session / embeddedID 纠缠, 难干净提取 |

**选定 A**. 模块边界事实 (`HostLauncher` 在 `hvm-cli` executable target, HVM app target 无法 import) 逼着必须有共享层; 既然要建, 建成正式 library 收口 3 份重复, 比复制粘贴干净. hvm-cli refactor 作为 M1 的一部分, 用 `hvm-cli list/start/stop/delete` e2e 回归兜底.

### 选型 2: 新 store 的 Observable 形态

| 方案 | 形态 | 优势 | 劣势 |
|---|---|---|---|
| **A. `@Observable @MainActor final class`** (Swift Observation) ✅ 选定 | `@Observable final class NewGUIStore`, 注入走 `.environment(store)` + 业务页 `@Environment(NewGUIStore.self)` | 细粒度更新 (只重绘读了变化字段的 view); 跟老 AppModel 同款 (`@Observable`), 心智一致; macOS 14 起原生支持 | 跟现有 DialogPresenter (`ObservableObject` + `@EnvironmentObject`) 两套注入并存 |
| B. `ObservableObject` + `@EnvironmentObject` | 跟 DialogPresenter 同款 `@Published` + EnvironmentObject | 注入方式跟 dialog 统一 | 粗粒度 (任一 @Published 变全 view 重算); list 1Hz 刷新会触发全树 diff |
| C. `@Observable` + 手动 `@State` 持有 | RootView `@State var store`, 往下传 binding | 无 environment | 深层 sidebar/detail 都要显式穿参, 啰嗦 |

**选定 A**. list 1Hz 高频刷新, 细粒度更新重要 (避免每秒全树重算, 直接关系 P0-2 帧率). DialogPresenter 维持 ObservableObject 不动 (它本就低频), 两套注入并存可接受 — Dialog 是横切关注点, store 是数据源, 职责不同分开注入反而清晰.

### 选型 3: 两栏布局底层

| 方案 | 形态 | 优势 | 劣势 |
|---|---|---|---|
| **A. 自绘 `HStack` 固定宽 sidebar (240) + 分隔线 + detail 自适应** ✅ 选定 | `HStack(spacing:0){ Sidebar().frame(width:240); HVMUI.Divider(.vertical); Detail() }` | 完全可控, 跟 Linear 固定窄 sidebar 一致; Theme token 直接套; 无系统 chrome 干扰 | sidebar 宽度暂不可拖 (本稿不做, 推后) |
| B. SwiftUI `NavigationSplitView` | 系统两栏容器 | 自带可拖分隔 + 折叠 | 系统会塞自家 list chrome / 选中高亮样式, 跟自绘 Theme 冲突 (违反"禁系统组件"约束); macOS 上 sidebar material 强制 vibrancy |
| C. AppKit `NSSplitViewController` 内嵌两个 HostingView | 老 GUI 同款 | 可拖 + 原生性能 | 把 AppKit 拉回来, 违背新 GUI"AppKit 仅限 NSWindow+delegate 两处"原则 |

**选定 A**. 固定窄 sidebar 是 Linear 风核心特征, 自绘最贴; 可拖宽度低优先 (Decision D4 留 v1.1). 避免 NavigationSplitView 的系统 vibrancy 跟 `bgBase #08090A` 打架.

## 实现要点

### 共享控制层 `HVMControl` (library target)

新建 `app/Sources/HVMControl/`, Package.swift 加 target:

```swift
.target(
    name: "HVMControl",
    dependencies: ["HVMCore", "HVMBundle", "HVMEncryption", "HVMIPC", "HVMStorage"]
),
```

依赖说明: HVMBundle (枚举/flock/config) + HVMEncryption (加密检测/routing) + HVMIPC (停止/状态 socket) + HVMStorage (DiskFactory.actualBytes 算实际占用) + HVMCore (Paths). **不依赖** HVMBackend / HVMDisplay / HVMQemu (那些是 host 子进程内的事, 控制层只 fork 子进程不链接它们).

`HVM` app target + `hvm-cli` target 都加 `"HVMControl"` 依赖.

#### `VMSummary` — 列表项值类型 (Sendable)

```swift
public struct VMSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let bundleURL: URL
    public let displayName: String
    public let guestOS: GuestOSType
    public let engine: Engine
    public var runState: RunState               // .stopped / .running (本稿二态; pause 推后)
    public let encryptionScheme: EncryptionSpec.EncryptionScheme?   // nil = 明文
    public var isEncrypted: Bool { encryptionScheme != nil }

    // 明文 VM 持完整 config; 加密 VM 解锁前 nil (字段从 routing 元数据兜底)
    public let config: VMConfig?

    // 概览展示用 (config 缺失时为 nil, UI 显 "—")
    public let cpuCount: Int?
    public let memoryMiB: UInt64?
    public let mainDiskLogicalGiB: UInt64?
}

public enum RunState: String, Sendable { case stopped, running }
```

#### `VMCatalog` — 枚举 (收口 ListCommand + AppModel.refreshList 的逻辑)

```swift
public enum VMCatalog {
    /// 扫 root (默认 HVMPaths.vmsRoot) 下所有 .hvmz, 返回 summary 列表 (按 displayName 排序).
    /// 加密 VM 不解密, 走 RoutingJSON 拿 displayName/guestOS/id; 明文走 BundleIO.load.
    /// 运行态走 BundleLock.isBusy (flock 非阻塞探测).
    public static func list(in root: URL = HVMPaths.vmsRoot) -> [VMSummary]

    /// 单个 bundle → summary (sidebar 刷新单项 / detail 重载用)
    public static func summary(for bundleURL: URL) -> VMSummary?
}
```

实现要点 (照 `ListCommand.swift:99-144` + `AppModel.refreshList:395-452` 合并):
- `BundleDiscovery.list(in: root)` 拿 `[URL]`
- 每个 bundle: `BundleLock.isBusy(bundleURL:)` → runState
- `EncryptedBundleIO.detectScheme(at:)` ≠ nil → 加密分支: `RoutingJSON.read(RoutingMetadata.locationForQemuBundle(url))` 拿 vmId/displayName/guestOS/scheme, config = nil
- 明文分支: `BundleIO.load(from:)` → config; cpu/mem/disk 从 config 取; `DiskFactory.actualBytes` 本稿先不算 (慢, 列表不需要实际占用, 留 detail 按需算)

#### `VMControl` — 动作门面

```swift
public enum VMControl {
    /// 启动 (fork --host-mode-bundle 子进程). 加密 VM 必须传 password (调用方负责 prompt).
    /// 返回子进程 pid. 已 running 抛 HVMError.bundle(.busy).
    @discardableResult
    public static func start(bundleURL: URL, password: String?) throws -> Int32

    /// 软关机 (ACPI). 走 BundleLock.inspect 拿 socketPath → SocketClient IPCOp.stop.
    public static func stop(bundleURL: URL) throws

    /// 强制关机. IPCOp.kill.
    public static func kill(bundleURL: URL) throws

    /// 查询运行态详情 (pid / startedAt / 实时 state). IPCOp.status → IPCStatusPayload.
    /// 未运行返回 nil.
    public static func status(bundleURL: URL) throws -> IPCStatusPayload?

    /// 删除. requireStopped 检查 → trash (默认) 或 purge (removeItem) 或 secureErase (加密+purge).
    public static func delete(bundleURL: URL, mode: DeleteMode) throws

    public enum DeleteMode: Sendable { case trash, purge, secureErase }
}
```

- `start`: `HostLauncher.launch` 迁入 `HVMControl` 后改名 `VMControl.start` (或内部仍叫 HostLauncher, public 入口走 VMControl). hvm-cli `StartCommand` 改调 `VMControl.start`
- `stop/kill/status`: 照 `StopCommand.swift:25-35` / `KillCommand` — `BundleLock.inspect` → `holder.socketPath` → `SocketClient.request(IPCRequest(op: IPCOp.X.rawValue))`
- `delete`: 照 `DeleteCommand.swift:40-80`

#### hvm-cli refactor (M1 内)

`ListCommand` / `StartCommand` / `StopCommand` / `KillCommand` / `DeleteCommand` 改调 `HVMControl` 对应入口, 删掉各自内联实现. `HostLauncher.swift` 从 `hvm-cli/Support/` 迁到 `HVMControl/`. 验收: `hvm-cli list` / `start` / `stop` / `kill` / `delete` 行为不变 (e2e 回归).

### 新 store `NewGUIStore`

`app/Sources/HVM/GUI/Store/NewGUIStore.swift`:

```swift
#if NEW_GUI
import Foundation
import Observation
import HVMControl
import HVMBundle
import HVMIPC

@MainActor
@Observable
public final class NewGUIStore {
    public private(set) var vms: [VMSummary] = []
    public var selectedID: UUID? = nil
    public private(set) var lastError: HVMError? = nil   // 冒泡给 MainLayoutView → dialog.alert

    private var pollTimer: Timer?

    public init() {}

    /// 启 1Hz 轮询 (refresh runState + 增删 VM 反映到列表). 由 RootView .onAppear 调.
    public func startPolling() { ... }   // Timer.scheduledTimer 1.0s → refresh()
    public func stopPolling() { ... }

    /// 重扫 VMCatalog.list, diff 合并进 vms (保留 selectedID; 列表内容变才赋值, 避免无谓重绘)
    public func refresh() {
        let fresh = VMCatalog.list()
        if fresh != vms { vms = fresh }
        if let sel = selectedID, !fresh.contains(where: { $0.id == sel }) {
            selectedID = fresh.first?.id   // 选中的 VM 被删 → 退选到第一个
        }
    }

    public var selected: VMSummary? { vms.first { $0.id == selectedID } }

    // 动作 — 失败写 lastError, MainLayoutView 监听弹 dialog.alert
    public func start(_ s: VMSummary, password: String?) { try? VMControl.start(bundleURL: s.bundleURL, password: password) / 捕获写 lastError; refresh() }
    public func stop(_ s: VMSummary) { ... VMControl.stop ... }
    public func kill(_ s: VMSummary) { ... VMControl.kill ... }
    public func delete(_ s: VMSummary, mode: VMControl.DeleteMode) { ... VMControl.delete ... }
}
#endif
```

要点:
- `@Observable` 细粒度: sidebar 读 `vms` + `selectedID`, detail 读 `selected` — 各自只在相关字段变时重绘
- 1Hz `refresh()` 内 `if fresh != vms` 守卫 (VMSummary Equatable), 列表无变化不赋值 → 不触发重绘, 保 P0-2 帧率
- 错误经 `lastError` 冒泡; `MainLayoutView` `.onChange(of: store.lastError)` 弹 `dialog.alert(level:.error)`. 启停是同步 throwing (HostLauncher.launch / SocketClient 同步); 长事务 (本稿无) 才走 Task
- **加密 VM 启动**: store 不自己 prompt; `SidebarView` / detail 启动按钮先判 `s.isEncrypted` → `await dialog.input(secure)` 拿密码 → `store.start(s, password:)`. 明文直接 `store.start(s, password: nil)`

### 主界面 `MainLayoutView`

`app/Sources/HVM/GUI/Layout/MainLayoutView.swift` — 替换 `NewGUIRootView` 成为默认 root:

```
┌── MainToolbarView (高 44, bgRaised, 底边 hairline) ──────────────────┐
│  [HVM]   ……spacer……   [⟳ 刷新]  [+ 新建 VM (primary)]              │
├──────────────┬──────────────────────────────────────────────────────┤
│ SidebarView  │  DetailOverviewView (选中 VM)                         │
│ width 240    │   ┌ 顶部: 名称 + guestOS badge + 加密 badge + 运行态  │
│ bgBase       │   │ HVMUI.Section "概览" { id/engine/cpu/mem/disk }    │
│ ┌ 列表标题   │   │ HVMUI.Section "操作" { [启动]/[停止]/[强制停止] }  │
│ │ ⦿ vm-1     │   └ (未选中 → 居中空态 "选择左侧 VM")                 │
│ │ ○ vm-2 🔒  │                                                       │
│ └ ……          │                                                       │
├──────────────┴──────────────────────────────────────────────────────┤
│ StatusBar 占位 (高 28, "N 台 VM · M 运行中")                          │
└──────────────────────────────────────────────────────────────────────┘
```

- 注入: `MainLayoutView` 持 `@State private var store = NewGUIStore()`, `.environment(store)` 往下传; `.onAppear { store.startPolling() }`
- `.hvmDialogHost()` 仍在 `NewGUIApp.swift` 的 NSHostingController 外层 (不动), MainLayoutView 内 `@EnvironmentObject dialog` 照拿
- 窗口尺寸: 维持现有 1080×720 锁死 (NewGUIApp.swift 不改)

### sidebar VM 列表行 `SidebarView`

每行 (probeID `vmlist.row.item-<vmID>`):
- 左: 运行态圆点 — running `HVMUI.Icon("circle.fill", color:.success)` / stopped `circle` `textTertiary`
- 中: displayName (`HVMTheme.font.base`, 选中 textPrimary / 否则 textSecondary)
- 右: guestOS badge (macOS→accent / linux→info / windows→warn) + 加密 `lock.fill` 锁图标 (isEncrypted)
- 选中行: `bgHover` 底 + 左侧 2px accent 竖条
- 点击: `store.selectedID = vm.id`
- 右键 context menu: 启动/停止 (按 runState 切) · 强制停止 (running) · 删除 (stopped, 走 confirm destructive)
- 行用 `.plain` button (list cell 允许裸 plain, 见 CLAUDE.md UI 约束例外), probeID 走自定义 hvmProbe 注册 (`.button` action = 选中)

### detail 最小 overview `DetailOverviewView`

- 未选中: 居中空态 (`HVMUI.Icon` 大图标 + "选择左侧 VM 查看详情" textTertiary)
- 选中 (明文 / 已解锁): `HVMUI.Section("概览")` 列 id (mono) / engine / cpu / memory / 主盘大小 / 运行态 badge; `HVMUI.Section("操作")` 放启停按钮
- 选中加密未解锁 (config=nil): overview 只显 displayName / guestOS / "🔒 加密 (解锁查看完整配置)"; 操作区只留 [启动] (启动时弹密码); "解锁查看" 推 `NEW_GUI_ENCRYPTION.md`, 本稿不做查看解锁
- 运行中: overview 顶部标 "运行中 — 画面嵌入待 framebuffer 子稿", 不嵌真画面

### probeID 命名 (R6 强制全覆盖)

| 控件 | probeID |
|---|---|
| toolbar 刷新 | `toolbar.button.refresh` |
| toolbar 新建 | `toolbar.button.create` |
| sidebar 行 | `vmlist.row.item-<vmID>` |
| detail 启动 | `detail.button.start` |
| detail 停止 | `detail.button.stop` |
| detail 强制停止 | `detail.button.kill` |
| 删除确认 dialog | `detail.confirm.delete` / context menu `vmlist.confirm.delete-<vmID>` |
| 启动密码 dialog | `vmlist.input.password-<vmID>` |

## 风险与待验证

### P0 (必须 gate, 阻塞合入)

- **P0-1: hvm-cli refactor 后行为不回归** — M1 把 5 个 command 改调 `HVMControl`. 必须 e2e: 造 throwaway 明文 Linux VM, `hvm-cli list` (字段一致) / `start` (能起) / `stop` (能停) / `delete --purge` (能删); 加密 VM `list` 走 routing 不崩. **未过不合 M1**
- **P0-2: 1Hz 轮询不掉帧** — `make run-app` (release) 开 5+ VM 列表, 每秒 refresh 不卡 sidebar hover/选中. `if fresh != vms` 守卫必须真生效 (VMSummary Equatable 正确实现, 含 runState). hvm-dbg gui screenshot 连拍验证无闪烁
- **P0-3: 加密 VM 启动密码闭环** — 加密 VM 点启动 → 弹 `dialog.input(secure)` → 输密码 → `VMControl.start(password:)` 透传 stdin → 子进程起. 密码错 → 子进程退出 → 1Hz 轮询读到仍 stopped → store.lastError 弹 alert. 用 agent 自家密码造加密 throwaway VM 跑通

### P1 (合入前知会, 不阻塞)

- `@Observable` store (`.environment`) 与 `ObservableObject` dialog (`@EnvironmentObject`) 两套注入并存的可维护性 — 先并存, 后续若统一再单独提
- VMSummary `config: VMConfig?` 在 Equatable diff 里参与比较 (VMConfig 已 Equatable) — 大 struct 每秒比较成本; 若 P0-2 实测慢, 改成只比较轻量字段 (id/runState/displayName) 的自定义 `==`
- detail running 不嵌真画面, 体验割裂 (用户点启动看不到画面) — 本稿明确标注, framebuffer 子稿补; 期间可提示 "用老 GUI (GUI=old) 看画面" 或推 framebuffer 子稿优先级

### P2 (留待后续)

- sidebar 宽度不可拖 (Decision D4)
- 列表不支持拖拽重排序 (老 GUI 有, 本稿按 displayName 排)
- 拖 .hvmz 进 sidebar 临时挂载 (老 dropEphemeralBundle) 推后

## PR 拆解

每 PR ≤ 2 天. 全走 `GUI=new`; M1 动 hvm-cli (共享层) 但不动老 GUI `UI/**`.

| PR | 标题 | 验收 |
|---|---|---|
| **M1** | refactor(control): 抽 HVMControl library (VMSummary + VMCatalog.list + VMControl.{start,stop,kill,status,delete}) + HostLauncher 迁入 + hvm-cli 5 命令改调 | `make build` 通过; hvm-cli list/start/stop/kill/delete e2e 回归 (P0-1); throwaway 明文+加密 VM 各跑一遍 |
| **M2** | feat(gui): NewGUIStore (@Observable + 1Hz poll + start/stop/kill/delete 转发 HVMControl + lastError 冒泡) | 编译通过; 无 UI 先用临时 debug 入口或 detail 验 store.vms 非空; refresh diff 守卫生效 |
| **M3** | feat(gui): MainLayoutView 两栏骨架 + MainToolbarView + StatusBar 占位, 替换 NewGUIRootView 成默认 (Showcase 退 HVM_GUI_SHOWCASE=1) | `make run-app` 打开见两栏; 空 VM 列表 / 有 VM 列表都正常; Showcase 仍可 env 开 |
| **M4** | feat(gui): SidebarView VM 列表行 (运行态圆点 + guestOS badge + 加密锁 + 选中高亮 + context menu) + probeID 全覆盖 | hvm-dbg gui list 见 `vmlist.row.*`; click 选中切 detail; context menu 启停/删除 |
| **M5** | feat(gui): DetailOverviewView (overview section + 启停按钮 + 加密未解锁兜底) + 启停接 store + 删除/密码 dialog | hvm-dbg gui 自动化: 选 VM → 看 overview → 点启动 (明文起 / 加密弹密码) → 点停止; 删除走 confirm |
| **M6** | feat(gui): toolbar 刷新/新建占位 + 错误 alert 冒泡 + e2e 全路径走查 + 回写文档 | hvm-dbg gui 跑通"选→启→停→删"全序列; 错误弹 alert; 回写 v1 现状 + CLAUDE.md 约束 + TODO |

**合入后回写**:
- `docs/v1/` 加新 GUI 主界面现状描述
- `CLAUDE.md` "GUI 约束" 节加新 GUI 主界面 / sidebar / store 约束 (probeID 命名 / HVMControl 单一来源 / 禁新 store 抄后端逻辑)
- `docs/v4/README.md` 索引标本稿状态 + NEW_GUI_VM_LIST.md 折叠说明
- `docs/TODO.md` 勾选 M1-M6

## 未决事项 (Decisions)

| ID | 决策 | 默认 | 决策时机 |
|---|---|---|---|
| **D1** | 共享控制层放哪 | **已决: 新 library `HVMControl`** (选型 1-A, 用户 store 解耦诉求 + 收口 3 份重复) | ✅ 本稿 |
| **D2** | 新 store Observable 形态 | **已决: `@Observable`** (选型 2-A, 细粒度保 1Hz 帧率) | ✅ 本稿 |
| **D3** | 两栏布局底层 | **已决: 自绘 HStack 固定 240 sidebar** (选型 3-A) | ✅ 本稿 |
| **D4** | sidebar 宽度可拖? | 不可拖 v1 (固定 240), 可拖留 v1.1 | 本稿不决 |
| **D5** | detail running 嵌画面 | 本稿不嵌 (标占位), 真画面走 `NEW_GUI_FRAMEBUFFER.md` | 已决推后 |
| **D6** | Showcase 去留 | 退到 `HVM_GUI_SHOWCASE=1` env 保留 (组件 living doc), 不删 | ✅ 本稿 |
| **D7** | 列表排序 | displayName 升序 v1; 自定义拖拽重排推后 | 本稿不决 |
| **D8** | VMSummary Equatable 是否含 config | 含 (VMConfig Equatable); 若 P0-2 实测慢改轻量 == | M2 实测后定 |

---

**待用户敲定**: 整体方向 (尤其 D1 抽 HVMControl library 这个 refactor 是否接受 — 它会动 hvm-cli) + PR 拆解粒度. 用户点头后开 M1.
