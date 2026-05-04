# PR-11: GUI 加密 VM 适配

> 状态: **设计稿 v1 (2026-05-04)** — 评审中
>
> 父设计稿: [ENCRYPTION.md](ENCRYPTION.md) v2.4 PR-11
> 关联 TODO: [TODO.md](TODO.md) #10

## 背景

PR-1 ~ PR-10b + PR-A/B/C 落地后, **CLI 加密路径全闭环**: create / start / encrypt / decrypt / rekey / clone / snapshot / status 都通. 但 **GUI 还按"明文 VM"假设**, 加密 VM 在 GUI 上完全用不了:

1. **`refreshList()` 走 `BundleIO.load`** → 加密 VM 是 `config.yaml.enc`, load fileNotFound 抛错被 `try?` 吞了 → **加密 VM 在 GUI 列表里直接不出现**
2. **`VMListItem` 强制要 `config: VMConfig`** → 加密 VM 没解密前没 config, 整个数据模型不兼容
3. **`AppModel.start(item, password: nil)` 默认 nil** → 加密 VM 启动撞 stdin EOF → host 进程 exit 40
4. **CreateVMDialog 没加密选项** → GUI 没法创建加密 VM
5. **CloneVMDialog 已显式传 `password: nil`** (PR-B 时改的) → 加密源被 CloneManager 拒
6. **没有 encrypt / decrypt / rekey 入口** → 只能跑 CLI

## 目标 + 范围

**做** (PR-11 完整范围):
- 数据模型: `VMListItem` 兼容加密 VM (config 可选 / 加密 VM 走 routing JSON 拿基础字段)
- `refreshList()`: 加密 VM 走 `EncryptedBundleIO.detectScheme` + `RoutingJSON.read`, 不解密
- 列表显示: 侧边栏 / 详情头部 显示加密标记 (锁图标 / 字样)
- **创建加密 VM**: CreateVMDialog 加 "加密" toggle + 双密码框
- **启动加密 VM**: Start 路径检测加密 → prompt 密码 modal → 透传到 `start(item, password)`
- **clone 加密 VM**: CloneVMDialog 检测加密源 → prompt 密码 + warning + 透传到 `CloneManager`
- **encrypt / decrypt / rekey**: 详情页 actions / 菜单加三个入口 + 三个新 dialog
- **错误处理**: 错密码 / 加密事务进行中 / 不可中断 — 全走 ErrorDialog

**不做** (out of scope, 推后):
- VZ-sparsebundle 加密 (推后跟 ENCRYPTION.md v2.4 一致)
- 密码强度评估 / Keychain 缓存 (v2.2 决策不缓存, 强制每次输)
- import-disk + encrypt 一步到位 (TODO #16, 单独项)
- secure-erase delete (TODO #11, 单独项)

## 选型对比

### D23: VMListItem 数据模型

| 方案 | 实现 | 优点 | 缺点 | 选用 |
|---|---|---|---|---|
| **A. config 改可选 + 加 isEncrypted/displayName/guestOS 兜底字段** | `config: VMConfig?` + 加密 VM 从 routing 派生显示用字段 | 改动最小, 兼容现有 view 逻辑 | views 处处 `if let config` 打补丁 | ✅ |
| B. 改 enum: plaintext(VMConfig) / encrypted(RoutingMetadata) | 类型严格, 编译器逼 view 处理两种 case | 重构面大 | 现有 30+ 处 view 全改 | ✗ |
| C. encrypted VM 不进列表, 单独 sidebar section | 不混合 | UX 割裂 | 用户总数 / sort 不一致 | ✗ |

**选 A**. 理由:
- 加密 VM 在 GUI 上的"基础信息" (displayName / guestOS / id) 都能从 routing JSON 拿到, 走兜底
- 大部分 view 关心 `displayName` / `runState` / `isEncrypted`, 这几个字段无 config 也能给
- 需要 config 的视图 (CPU / 内存 / 磁盘大小) 显式 `if let cfg = item.config` 处理 — 加密 VM 显示 "解锁后查看" 占位

### D24: 启动期密码 modal

| 方案 | 实现 | UX | 选用 |
|---|---|---|---|
| **A. HVMModal 弹层 + HVMTextField (secure)** | 走自家组件 (CLAUDE.md UI 约束) | 跟其他 dialog 一致 | ✅ |
| B. NSAlert + 输入框 | macOS 原生 | 违反 CLAUDE.md "禁止 NSAlert" | ✗ |
| C. inline 在详情页内嵌 | 不弹层 | 用户可能没看到密码框 / 多 VM 同时输混乱 | ✗ |

**选 A**. 重用现有 HVMModal + HVMTextField (要 `isSecure: Bool` 参数, 现有支持).

### D25: encrypt / decrypt / rekey 入口

| 方案 | 实现 | 选用 |
|---|---|---|
| **A. 详情页 "加密" 子区 + 三个按钮** (条件显示) | 加密 VM 显示 decrypt + rekey; 明文显示 encrypt | ✅ |
| B. 全局菜单栏 / context menu | 隐蔽, 用户找不到 | ✗ |
| C. 装机向导第二步 | 跟 lifecycle 不一致 (encrypt 是 in-place 老 VM 转换) | ✗ |

**选 A**. 加密区跟 "网络" / "磁盘" 子区平行. 三个按钮分别打开 EncryptDialog / DecryptDialog / RekeyDialog.

### D26: 加密事务进行中的 GUI 阻断

CLI 走 SignalGuard 拦 Ctrl-C; GUI 没 Ctrl-C 概念, 但用户可能:
- 点 X 关 dialog → 中断事务?
- 关闭 HVM 主窗口 / Cmd-Q

**主张**: encrypt / decrypt / rekey dialog **强制不可关** (`HVMModal closeAction = nil` 隐藏 X), 文案 "操作进行中, 请等待结束". 用户必须等. 跟 CLI SignalGuard 第一次警告等同.

后台跑 (`Task.detached`), 完成回主线程切 dialog 状态 → done / error.

## 实现要点

### 1. VMListItem 数据模型 (`AppModel.swift`)

```swift
public struct VMListItem: Identifiable, Sendable {
    public let id: UUID                  // routing.vmId 或 config.id
    public let bundleURL: URL
    public let displayName: String       // routing.displayName 或 config.displayName
    public let guestOS: GuestOSType      // 加密 VM 走 routing 兜底默认 .linux (因 routing 不存 guestOS — 见下)
    public let config: VMConfig?         // ← 改可选; 加密 VM 解锁前 nil
    public let encryptionScheme: EncryptionSpec.EncryptionScheme?  // ← 新增; nil = 明文
    public var runState: String

    public var isEncrypted: Bool { encryptionScheme != nil }
}
```

**注**: routing JSON 不存 guestOS (因 v2 schema 没包). 兜底策略:
- 加密 VM 解锁前: 显示 "encrypted" placeholder, 详情页提示"启动后/解锁后显示"
- 加密 VM 运行中: 走 IPC 拿 `IPCStatusPayload.guestOS` (PR-10b 已支持)
- routing JSON 加 guestOS 字段升 v3 schema (跟 ENCRYPTION.md 升级链); 或干脆**不补**, 让用户接受"加密 VM 列表显示 'encrypted'"

**主张不补 guestOS 字段** (D27): UX 上加锁图标 + "加密 VM" 标识比 guestOS 类型重要. 后续若要 guestOS, 跑 IPC 拿运行时数据.

### 2. refreshList 加密分支

```swift
for u in urls {
    let scheme = EncryptedBundleIO.detectScheme(at: u)
    if let scheme = scheme {
        // 加密路径
        let routingURL: URL = ...  // 按 scheme 拿
        guard let routing = try? RoutingJSON.read(from: routingURL) else { continue }
        let item = VMListItem(
            bundleURL: u,
            id: routing.vmId,
            displayName: routing.displayName,
            guestOS: .linux,  // 占位; 详情页显示 "启动后查看"
            config: nil,
            encryptionScheme: scheme,
            runState: busy ? "running" : "stopped"
        )
        items.append(item)
    } else {
        // 现有明文路径 BundleIO.load
        ...
    }
}
```

### 3. 启动期密码 modal

新文件 `app/Sources/HVM/UI/Dialogs/EncryptionPasswordDialog.swift`:

```swift
struct EncryptionPasswordDialog: View {
    let displayName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    
    @State private var password: String = ""
    @State private var error: String? = nil
    
    var body: some View {
        HVMModal(title: "解锁加密 VM", closeAction: onCancel) {
            VStack(spacing: HVMSpace.md) {
                Text("VM \"\(displayName)\" 已加密. 输入密码继续.")
                HVMTextField("密码", text: $password, isSecure: true)
                if let err = error { Text(err).foregroundColor(.red) }
            }
        } footer: {
            HStack {
                Button("取消", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("解锁") { onSubmit(password) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(password.isEmpty)
            }
        }
    }
}
```

`AppModel.start(item)` 改:

```swift
public func start(_ item: VMListItem) async throws {
    if item.isEncrypted {
        // 弹密码 modal, 等待用户输入 (绑 @Published var pendingPasswordPrompt: ...)
        let password = await promptPassword(for: item)
        guard let pw = password else { return }   // 用户取消
        try await startInternal(item, password: pw)
    } else {
        try await startInternal(item, password: nil)
    }
}
```

### 4. CreateVMDialog 加密分支

加 `@State var enableEncryption: Bool` + `@State var password / passwordConfirm: String`. Toggle 显示双密码框. 校验:
- 密码长度 ≥ 4
- 两次一致

提交时:
- `enableEncryption == false` → 现有 `BundleIO.create + DiskFactory.create` 路径
- `enableEncryption == true` → `EncryptedBundleIO.create(parentDir, displayName, password, baseConfig, scheme: .qemuPerfile)` + `QcowLuksFactory.create` 用 sub.qcow2Disk + `OVMFVarsLuksFactory.create` (Win) + `EncryptedConfigIO.save`

参考 CLI [CreateCommand.swift](app/Sources/hvm-cli/Commands/CreateCommand.swift) 的 createEncryptedVM 函数.

### 5. CloneVMDialog 加密源

之前显式 `password: nil` 改成: 检测源是否加密 → 加密则 prompt + warning, 跟 [CloneCommand.swift](app/Sources/hvm-cli/Commands/CloneCommand.swift) 加密分支同款 UX.

### 6. 详情页加密区

`DetailContainerView` 加 "加密" 子节, 平行于 "网络" / "磁盘" / "TPM":

- 明文 VM: 显示 "明文" + `[加密 → 加密这台 VM]` 按钮
- 加密 VM: 显示 scheme + KDF 参数 (从 routing JSON) + 两按钮 `[改密]` `[转明文]`

按钮分别打开:
- `EncryptVMDialog` (新): prompt 双密码 + warning, 跑 `EncryptVMOperation.encrypt` 后台 task
- `DecryptVMDialog` (新): prompt 密码 + warning, 跑 `DecryptVMOperation.decrypt`
- `RekeyVMDialog` (新): prompt 旧密 + 双新密 + warning (TPM 重置), 跑 `RekeyVMOperation.rekey`

三个 dialog 共用 progress modal 模式: 提交后 closeAction = nil + spinner + 实时打 progressLog 行 (类似 InstallDialog).

### 7. 错误路径

- 错密码 → `HVMError.encryption(.wrongPassword)` 在 dialog 内 inline 显示, 让用户重试 (不退出 dialog)
- 加密事务跑中 (rekey 等) crash → 重启 GUI 后, refreshList 仍能识别加密 VM, 用户可重试

## 风险与待验证项

| 编号 | 风险 | 验证 | 阻断 |
|---|---|---|---|
| R7 | refreshList 加密分支频繁读 routing JSON I/O 开销 | mtime 缓存复用 (跟现状明文路径一样); routing JSON < 1KB, 实测可忽略 | 已论证 |
| R8 | 加密 VM 解锁中 GUI 主窗口被关 → password modal dismiss 但 unlock 已 in-flight | promptPassword 用 continuation, dismiss → cancel; unlock 抛错 → ErrorDialog | P1 |
| **R9** | encrypt/decrypt/rekey 后台 Task 跑期间 GUI 进程被 Cmd-Q | atexit cleanup (PR-C 已加) 跑掉临时目录; 但 GUI 强 quit 路径不调用 atexit (`exit(_)` 才走). NSApplication 走 `terminate:` 默认会调 atexit | P1, 实测 |
| R10 | 多 VM 同时并发加密事务 GUI 性能 | Task.detached 后台跑, 不阻 UI; SignalGuard 嵌套 reentrant 计数 OK | 已论证 |

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 | 状态 |
|---|---|---|---|
| **PR-11a** | 数据模型重构: `VMListItem.config` 改可选 + 加 `encryptionScheme`. `refreshList` 加密分支走 routing JSON. 现有 view 用 config 处加 `if let` 兜底. SidebarView / DetailBars 显示加密标记 (锁图标) | 0.5 天 | 待开 |
| **PR-11b** | 启动加密 VM: 新 `EncryptionPasswordDialog`. AppModel.start 检测 → prompt → password 透传到 spawnExternalHost. 错密码 inline 显示 | 0.5 天 | 待开 |
| **PR-11c** | CreateVMDialog 加密: toggle + 双密码框 + 校验 + 提交走 EncryptedBundleIO.create + 各加密 factory | 0.5 天 | 待开 |
| **PR-11d** | CloneVMDialog 加密源: prompt + warning + 透传 password. 复用 EncryptionPasswordDialog | 0.3 天 | 待开 |
| **PR-11e** | 详情页加密区 + EncryptVMDialog / DecryptVMDialog / RekeyVMDialog. 后台 Task + progress 显示 | 1 天 | 待开 |
| **PR-11f** | 真机 e2e: 创建加密 VM → 启动 → encrypt 老 VM → decrypt → rekey → clone → snapshot. 错密码 / 强 quit 测试 | 0.5 天 | 待开 |
| **PR-11g** | docs 回写: TODO #10 标 Done; CLAUDE.md GUI 加密约束节; v1/GUI.md 同步 | 0.2 天 | 与 PR-11f 合 |

合计 ~3.5 天 / 1 人. PR-11a 是基础, 其他 b/c/d/e 可在 a 之上**并行**起草 (但实际单人串行).

每个 PR `make build` 通过 + 真机点一遍涉及功能.

## 未决事项

| 编号 | 问题 | 主张 | 决策时机 |
|---|---|---|---|
| **D23** | VMListItem 数据模型 | A: config 改可选 + isEncrypted 字段 | 本稿 |
| **D24** | 启动密码 modal 形态 | A: HVMModal + HVMTextField (secure) | 本稿 |
| **D25** | encrypt/decrypt/rekey 入口 | A: 详情页加密区 + 三按钮 | 本稿 |
| **D26** | 加密事务期 dialog 不可关 | 主张: closeAction = nil, 跟 CLI SignalGuard 等价 | 本稿 |
| **D27** | routing JSON 是否补 guestOS (升 v3 schema) | **不补** — 显示 "加密 VM" 占位; 启动后 IPC 拿真实 guestOS | 本稿 |
| **D28** | 加密事务跑期 GUI 主窗口 Cmd-Q 行为 | NSApplicationDelegate `applicationShouldTerminate` 检事务进行中 → 弹 confirm "操作进行中, 强退可能损坏数据"; 用户选 "等待" 或 "强退" | 本稿 |
| D29 | 列表锁图标用 SF Symbol 还是自绘 | `lock.fill` SF Symbol; 解锁运行中可加点动画 | 已决 |

## 设计变更日志

### 2026-05-04 v1 — 本稿

初稿. 关键决策:
- D23 选 A (config 可选 + 兜底字段) — 改动最小
- D24/25/26 都走 HVMModal + 详情页内嵌, 跟 CLAUDE.md UI 约束一致
- D27 不补 routing JSON guestOS, 维持 schema v2

## 相关文档

- 父稿 [ENCRYPTION.md](ENCRYPTION.md) v2.4 PR-11
- TODO 索引 [TODO.md](TODO.md) #10
- 实现参考 (CLI 已落):
  - [CreateCommand.swift](../../app/Sources/hvm-cli/Commands/CreateCommand.swift) (createEncryptedVM)
  - [StartCommand.swift](../../app/Sources/hvm-cli/Commands/StartCommand.swift) (PasswordPrompt + spawn)
  - [EncryptCommand.swift](../../app/Sources/hvm-cli/Commands/EncryptCommand.swift) / DecryptCommand / RekeyCommand
  - [CloneCommand.swift](../../app/Sources/hvm-cli/Commands/CloneCommand.swift) (加密源 prompt)
- UI 约束: [CLAUDE.md](../../CLAUDE.md) "UI 控件使用约束" 节
