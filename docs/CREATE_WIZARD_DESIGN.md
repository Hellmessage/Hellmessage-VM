# CREATE_WIZARD_DESIGN.md — 新 GUI 创建向导设计稿 (业务页 #4)

> 状态: **已落地** (2026-05-31). 决策 D1-D6 见 §6 表。实现合入: `HVMControl/VMControl+Create.swift` (创建单一来源) + `HVMUIWizardDialog.swift` (canAdvance + onComplete 扩展) + `GUI/Dialogs/CreateWizard.swift` (3 步装配) + `NewGUIStore.create` + sidebar 接入。约束已回写 `GUI.md §7.4` + `CLAUDE.md`「新 GUI 创建向导 (业务页 #4)」。本稿降为历史参考。

## 1. 目标 + 范围

新 GUI (`GUI=new`) 接入 **VM 创建向导**, 替换 `sidebar.button.create` 当前的占位 alert
(`NewGUISidebarView.swift:48` "创建向导即将接入"), 让用户不必退回 `hvm-cli create` / 老 GUI。

### 做 (v1)

- Linux arm64 / Windows arm64 (标「实验性」) 两种 guest 的明文 VM 创建
- 名称 / CPU / 内存 / 主盘大小 / 网络模式 配置
- 安装 ISO 选择 (NSOpenPanel, 走 `ISOValidator` 校验)
- **加密 VM** 创建 (toggle + 密码, 走 `EncryptedBundleIO` + `QcowLuksFactory`, 跟 CLI `--encrypt` 同路)
- Windows guest 选项 (Secure Boot / TPM / 跳过硬件检查 / 自动装 SPICE tools)
- Windows guest tools (UTM Guest Tools ISO) **前台下载** (带进度), 与 `GUEST_OS_INSTALL.md` 既定一致
- 创建成功后刷新 list + 自动选中新 VM

### 不做 (推后 / 越界)

- **导入现成磁盘镜像** (`--import-disk`) — 推后到 v1.1 (D1, 默认不纳入)
- **macOS guest** — 已随 VZ 下线 (能力边界约束)
- **x86_64 / riscv guest** — 能力边界约束
- **克隆** — 已有独立 `CloneVMDialog` 范畴 (CLI 已支持; 新 GUI 克隆是另一子稿)
- **bridged 网络的物理接口枚举** — v1 网络只给 nat/shared/host/none; bridged 推后 (D5)

## 2. 选型对比

### 2.1 dialog 实现: 扩展通用 WizardDialog vs 自绘专用 dialog

CLAUDE.md「UI 控件使用约束」: **"现有组件不满足时先扩展 / 改造现有组件, 而不是新建别名或绕开自绘"**。
创建向导是典型多步骤向导, `HVMUIWizardDialog` 就是为此而生 —— 应**扩展它**, 不另起炉灶。
现状它缺两点: per-step 校验 gating + "创建中" running 态。两者都能以**通用方式**补进 (任何向导通用, 非 create 专属)。

| | 方案 A — 扩展 `WizardDialog` (推荐) | 方案 B — 自绘 `NewGUICreateWizard` |
|---|---|---|
| 符合「扩展现有组件」约束 | ✓ | ✗ 绕开自绘组件, 新建平行 dialog |
| step 指示器 / 导航 | 现成复用 | 自绘重写 (重复代码) |
| per-step 校验 gating | 补 `WizardStep.canAdvance` (通用) | 自管 |
| "创建中" running 态 | 补 `onComplete` async + 内部 `.running` 态 (通用) | 自管 phase |
| 失败回填 + 内联 error | `onComplete` 返 `.failure(msg)` → 回 form 显红字 | 自管 |
| 跨步数据 | 外挂 class model (组件文档既定模式) | dialog 自身 `@State` |
| 代码量 / 维护 | 少 + 单一组件 | 多 + 两份向导逻辑漂移风险 |

**推荐方案 A (扩展 WizardDialog)**。两处通用扩展:

1. `WizardStep.canAdvance: () -> Bool`(默认 `{ true }`)— gate "下一步/完成" 按钮 disable
2. `WizardDialog.onComplete: (@MainActor @Sendable () async -> WizardCompletion)?` —
   "完成" 按下后切内部 `.running` 态 (隐藏 X + 导航, spinner + label), await; `.success` → `onResult(.completed)`,
   `.failure(msg)` → 回 form 态显内联 error。不传 `onComplete` 时退化为现有行为 (完成即 `.completed`)。

跨步数据走 `@MainActor` class model (组件自身文档注释既定: "跨步骤共享数据走 @EnvironmentObject 注入或
closure 内捕获 class-based model"), 因 `WizardDialog` 用 `.id(currentIndex)` 强制每步 `@State` 重建。

### 2.2 create 逻辑归属: GUI store 自实现 vs 收口 HVMControl

当前创建逻辑 **全在 `CreateCommand.swift`** (CLI), `VMControl` 无 `create`。

| | 方案 A — store 直接拼 BundleIO/DiskFactory/EncryptedBundleIO | 方案 B — 抽 `VMControl+Create.swift` (HVMControl), CLI + store 共用 |
|---|---|---|
| 一致性 | ✗ 与 CLI 两份创建逻辑, 必漂移 (CLAUDE.md 明令禁止抄第二份) | ✓ 单一来源, 两端自动同步 |
| 改动面 | 仅 GUI | CLI `CreateCommand` 需改调 (回归风险) |
| 符合约束 | ✗ 违反「VM 控制走 HVMControl 单一来源」 | ✓ |

**推荐方案 B (强制)** — 这是 CLAUDE.md「新 GUI 主界面」约束的硬要求:
> 禁止业务侧 / store 再抄一份…拼装逻辑。新增控制能力先加到 `VMControl`, 两端自动同步。

## 3. 实现要点 / 接口设计

### 3.1 `HVMControl/VMControl+Create.swift` (新文件)

把 `CreateCommand.run()` 里的创建逻辑搬过来, 抽成参数结构 + 静态方法:

```swift
public extension VMControl {
    /// 创建参数 (CLI + GUI 共用; 校验由调用方做, 这里只执行)
    struct CreateSpec: Sendable {
        var name: String
        var guestOS: GuestOSType
        var cpuCount: Int
        var memoryGiB: UInt64
        var diskGiB: UInt64
        var networkMode: NetworkMode
        var bridgedInterface: String?
        var macAddress: String?          // nil → 随机
        var installerISO: String?        // Linux/Windows 装机 ISO 绝对路径
        var parentDir: URL?              // nil → HVMPaths.vmsRoot
        var windows: WindowsSpec?        // guestOS==.windows 时
        // 加密
        var encrypt: Bool
        var password: String?            // encrypt 时必填
    }

    /// 创建明文/加密 VM, 返回 bundleURL。内部分流明文 (BundleIO+DiskFactory) / 加密
    /// (EncryptedBundleIO+QcowLuksFactory+OVMFVarsLuksFactory)。失败清残留 bundle。
    static func create(_ spec: CreateSpec) throws -> URL
}
```

- 卷空间预检 / qemu-img 解析 / OVMF VARS LUKS (Windows 加密) / 失败清残留 —— 全部从
  `CreateCommand` 平移过来, **逻辑不变**。
- `CreateCommand` 改为: 解析 argv → 拼 `CreateSpec` → 调 `VMControl.create` → 打印结果。
  `--import-disk` 路径暂留在 CreateCommand 内 (GUI v1 不接, 不进 CreateSpec; D1)。
- MAC 解析 / 网络字符串解析 (`parseNetwork`) 留在 CLI (argv 专属); GUI 直接传枚举值。

### 3.2 `NewGUIStore.create(...)` (扩 store)

```swift
public func create(_ spec: VMControl.CreateSpec) async -> (ok: Bool, bundleURL: URL?, error: String?)
```

- `Task.detached` 跑 `VMControl.create` (加密 qcow2 LUKS create 虽快, 仍不阻 main)
- 成功 → 回主线程 `refresh()` + `selectedID = 新 VM id`
- 失败 → 返 `error` (HVMError.userFacing), 由 dialog 内联显示 (**不**设全局 `lastError`, 避免双弹, 跟加密 dialog 一致)
- guest tools / virtio-win 下载 **不在此方法**, 由 dialog 在 Windows 步单独调
  `UtmGuestToolsCache.ensureCached(progress:)` (前台进度)

### 3.3 `WizardDialog` 通用扩展 (`HVMUIWizardDialog.swift`)

```swift
struct WizardStep {
    let title: String
    let content: () -> AnyView
    let canAdvance: () -> Bool        // NEW: gate "下一步/完成"; 默认 { true }
}

enum WizardCompletion: Sendable { case success; case failure(String) }

struct WizardDialog: View {
    // ...现有 title/steps/probeID/onResult...
    let onComplete: (@MainActor @Sendable () async -> WizardCompletion)?  // NEW, 可选
    // 内部 @State phase: .form / .running / 失败回 .form + inlineError
}
```

- 不传 `onComplete` → 退化为现有行为 ("完成" 即 `onResult(.completed)`), Showcase / 其它向导不受影响。
- 传 `onComplete` → "完成" 切 `.running`: 隐藏 X + 导航 + step chip 不可点, 显 spinner + label; await 结果:
  `.success` → `onResult(.completed)`; `.failure(msg)` → 回 `.form` 当前步 + 内联红字。
- "下一步/完成" 按钮 `disabled: !steps[currentIndex].canAdvance()`。

### 3.4 `app/Sources/HVM/GUI/Dialogs/CreateWizard.swift` (新文件, 业务装配)

不是新 dialog 组件, 只是 **装配 `WizardStep` 数组 + 一个 `@MainActor` 跨步 model**, 喂给扩展后的 `WizardDialog`:

```swift
@MainActor final class CreateWizardModel: ObservableObject {
    @Published var name = ""
    @Published var guestOS: GuestOSType = .linux
    @Published var cpu = 4
    @Published var memGiB: UInt64 = 4
    @Published var diskGiB: UInt64 = 64
    @Published var networkMode: NetworkMode = .user
    @Published var isoPath: String?
    @Published var encrypt = false
    @Published var password = ""; @Published var passwordConfirm = ""
    @Published var win = WindowsSpec()
    // 派生: toCreateSpec() -> VMControl.CreateSpec
}
```

- **步骤** (D2=3 步表单 + 创建中; D4 加密独立步; D5 bridged 进 v1). Linux/Windows 均 3 步, Windows 选项作 step2 条件子区:
  1. **系统** — 名称 (`HVMUI.TextField`, 必填非空 + 不重名) + Guest OS (`HVMUI.Select`: Linux / Windows「实验性」)
     + 网络模式 (`HVMUI.Select`: NAT/shared/host/bridged/none); 选 bridged → 物理接口
     (`HVMUI.Select`, 复用 `HostNetworkInterfaces.list()`, 同详情页网络段)
  2. **介质与资源** — ISO 选择 (NSOpenPanel, 必填 + `ISOValidator`) + CPU / 内存 / 主盘大小
     + Windows 专属子区 (仅 windows): Secure Boot / TPM / 跳过硬件检查 / 自动装 SPICE tools toggle
     + Windows guest tools 下载状态 + [下载] 按钮 (缺失时, 调 `UtmGuestToolsCache.ensureCached` 前台进度)
  3. **加密** (独立步) — encrypt toggle + 密码 / 确认 (开则必填≥4 且两次一致) + 忘记密码不可恢复警告
- **canAdvance**: step1 名称非空且不重名 + (bridged 时已选接口); step2 ISO 已选且合法; step3 加密开则密码≥4 且两次一致。
- **onComplete**: `await store.create(model.toCreateSpec())` → 映射 `WizardCompletion`。
- **跨步 model 注入**: `CreateWizardModel` 由 sidebar 装配时 `let model = CreateWizardModel()`, 各 step content
  closure 捕获它 (跟 store 一样 closure 捕获, 不走 @Environment, 因 dialog overlay 在 store 环境外层)。

### 3.5 sidebar 接入

`NewGUISidebarView.footer` 的 `sidebar.button.create` 动作: 构造 `CreateWizardModel` + steps,
`dialog.present { handle in WizardDialog(title:"新建虚拟机", steps: createSteps(model, store, handle), probeID:"dialog.create", onResult:..., onComplete:{ ... }) }`。
(store + model 均 closure 捕获显式传入, 同加密 dialog: overlay 在 `.environment(store)` 外层)。

### 3.6 probeID 命名 (新 GUI 强制 probeID)

- 触发: `sidebar.button.create` (现有)
- dialog (WizardDialog 派生): `dialog.create.{close,cancel,prev,next,complete}` + `dialog.create.step.<idx>` (仅已完成步可点)
- step1: `dialog.create.field.name` / `dialog.create.select.{os,network,bridgedIface}`
- step2: `dialog.create.field.{cpu,memory,disk}` / `dialog.create.iso.{select,clear}` /
  `dialog.create.win.{secureBoot,tpm,bypassChecks,spiceTools,downloadTools}`
- step3: `dialog.create.encrypt.{toggle,password,confirm}`

## 4. 风险与待验证项

- **P0-1 CLI create 回归** — `CreateCommand` 改调 `VMControl.create` 后, 必须回归
  Linux 明文 / Windows 明文 / `--encrypt` / `--import-disk` 全路径 (`build/hvm-cli create ...`)。
  重构等价性是第一 gate。
- **P0-2 加密收口** — 加密创建逻辑 (EncryptedBundleIO + QcowLuksFactory + OVMFVarsLuksFactory)
  必须搬进 `VMControl.create`, store/dialog 不碰; grep 确认无第二份。
- **P0-3 失败清残留** — 任意一步抛错 → `removeItem(bundleURL)`, 绝不留 partial bundle (CreateCommand 已有, 平移保留)。
- **P0-4 guest tools 下载** — Windows 步前台 `ensureCached` 带进度; 下载失败 fail-soft (允许继续创建, 装机时无驱动, 给提示)。
- **P0-5 创建后状态** — 成功刷新 list + 自动选中新 VM; dialog 自动关。
- **待验证 (e2e)** — `HVM_GUI_PROBE=1` 起 server, `hvm-dbg gui` 自动化跑创建 throwaway Linux VM 全程
  (type name → select os → 选 ISO → next → create → 验证 list 出现新 VM + bundle 落盘)。
  Windows / 加密路径若本地无 ISO/耗时, 在交付报告显式标「未实测」。

## 5. PR 拆解

| PR | 内容 | 时间盒 | 验收 |
|---|---|---|---|
| PR-A | 抽 `VMControl+Create.swift` + `CreateCommand` 改调 | ≤1天 | `make build` + `hvm-cli create` Linux/Win/encrypt 回归通过 |
| PR-B | 扩展 `WizardDialog` (canAdvance + onComplete) + `CreateWizard` 装配 (Linux 明文) + `store.create` + sidebar 接入 | ≤1.5天 | `make build`; hvm-dbg gui 自动化建 Linux throwaway VM; Showcase wizard 不回归 |
| PR-C | 加密 toggle + Windows 选项 + guest tools 前台下载 | ≤1.5天 | `make build`; 加密/Win 路径手动或 dbg 验证 |
| PR-D | 回写 `GUI.md §7.4` + `CLAUDE.md` 新 GUI 小节 + probeID 表 (并入 PR-C commit) | — | 文档与实现一致 |

## 6. 未决事项 (Decisions)

| # | 议题 | 决策 (2026-05-31 敲定) |
|---|---|---|
| D1 | `--import-disk` 是否纳入 GUI v1 | **不纳入** (推后 v1.1) |
| D2 | 步骤拆分 | **3 步表单 + 创建中** (系统+网络 / 介质+资源 / 加密) |
| D3 | dialog 实现方案 | **扩展 WizardDialog** (补 canAdvance + onComplete 两处通用扩展) |
| D4 | 加密放独立步 vs 并入 | **独立步** (step3 = 加密) |
| D5 | bridged 网络是否进 v1 | **进 v1** (复用 `HostNetworkInterfaces.list()` + `HVMUI.Select`, 同详情页网络段) |
| D6 | 创建后是否自动启动 VM | **不自动启** (仅 refresh + 选中新 VM, 与 CLI 一致) |
