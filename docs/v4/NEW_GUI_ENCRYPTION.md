# 新 GUI 业务页 — 加密 / 解密 / rekey dialog

> 状态: **设计稿** 2026-05-30 — 待用户评审. 业务页 #3.
>
> 前置依赖: [NEW_GUI.md](NEW_GUI.md) 基础设施 (Dialog 框架 + HVMUI 组件) + [NEW_GUI_MAIN_LAYOUT.md](NEW_GUI_MAIN_LAYOUT.md) (`NewGUIStore` + `HVMControl`) + [NEW_GUI_VM_DETAIL.md](NEW_GUI_VM_DETAIL.md) (详情页 section 框架 + V2 解锁流程已落 `unlock/lock/unlockedSubKeys`).
>
> 底层加密能力已全部落地 (CLI + Operation 层), 本稿只做**新 GUI 的事务 dialog + 入口 + store async 方法**, 不碰加密算法/格式. 决策溯源: [docs/v3/ENCRYPTION.md](../v3/ENCRYPTION.md) (v2.4) + [docs/v3/GUI_ENCRYPTION.md](../v3/GUI_ENCRYPTION.md) (老 GUI PR-11).

---

## 目标

把"整 VM 加密事务"接进新 GUI (`GUI=new`):

- **加密** (明文 QEMU VM → 加密 VM): 详情页"加密"区 [加密 VM…] → 双密码 → 后台 `EncryptVMOperation.encrypt` → 进度 → done
- **解密** (加密 VM → 明文 VM): [解密…] → 单密码 → `DecryptVMOperation.decrypt` → done
- **改密 (rekey)**: [改密…] → 原密码 + 新密码 → `RekeyVMOperation.rekey` (LUKS keyslot 重写, 毫秒级)
- 三个事务都是 **form → running → done 三态自定义 dialog**, running 态 `closeAction = nil` 不可关 (CLAUDE.md X-only-close + 加密事务不可中断)
- Windows guest 的加密/改密 **重置 TPM** → form + done 态显式红字预警 (BitLocker recovery key 丢失)

### 不做 (out of scope)

- **创建加密 VM** (CreateVMDialog 的加密 toggle) → 留 `NEW_GUI_CREATE_VM.md` (创建向导子稿一起做)
- **加密 VM 克隆** (同密码等价复制) → 留 clone 接入 / CreateVM 子稿; 当前 CLI `hvm-cli clone` 已支持
- **VZ-sparsebundle 加密** → 底层未接入 (ENCRYPTION.md 推后), 本稿仅 `qemuPerfile` scheme; VZ 加密 VM 入口灰显 + 文案
- **解锁查看/编辑配置** → 已在 VM_DETAIL V2 落地 (`unlock/lock`), 本稿不重做; 但解密/改密 **不要求先解锁** (dialog 自己收密码)
- **加密进度的精确百分比** → Operation 层只给 `progressLog: (String)->Void` 文本行, 本稿照搬文本日志滚动展示, 不做进度条

---

## 项目当前状态 (设计前提)

底层已具备 (CLI 已用同一套):

| 能力 | 入口 | 同步/async | 耗时 | 备注 |
|---|---|---|---|---|
| 加密 | `EncryptVMOperation.encrypt(bundleURL:password:qemuImg:ovmfVarsTemplate:progressLog:)` → `Result{tpmReset}` | 同步 throws | 分钟级 (qemu-img convert LUKS) | 拒已加密 / 拒非 QEMU / 拒 macOS guest |
| 解密 | `DecryptVMOperation.decrypt(bundleURL:password:qemuImg:progressLog:)` → `Result` | 同步 throws | 分钟级 (qemu-img convert) | 仅 `.qemuPerfile`; 无 TPM 重置 |
| 改密 | `RekeyVMOperation.rekey(bundleURL:oldPassword:newPassword:qemuImg:progressLog:)` → `Result{tpmReset}` | 同步 throws | 毫秒级 keyslot + 秒级 config 原子写 | 老+新密码都活 (加 keyslot) |
| 状态 | `EncryptedBundleIO.detectScheme(at:displayName:)` → `EncryptionScheme?` | 同步 | 即时 | 走 routing JSON, 不解密 |

`VMSummary` 已带 `isEncrypted` / `encryptionScheme` (V2). 路径解析 `QemuPaths.qemuImgBinary()` / `QemuPaths.resolveRoot()/share/qemu/edk2-aarch64-vars.fd` (Win OVMF VARS 模板) 已被 CLI 用.

新 GUI dialog 基础设施 (`HVMUI.DialogPresenter`):
- `present { handle in CustomView }` + `onDismiss` — 可推**完全自定义**三态 dialog, `handle.close()` 关闭, 栈式管理
- 已有 `confirm/input/alert/wizard` async — 但加密事务需要 running 态进度日志 + 三态切换, **标准 input 不够**, 走 custom present

---

## 选型对比

### 选型 1: dialog 形态 — 自定义三态 vs 标准 input + 独立进度

| 方案 | 做法 | 优 | 劣 |
|---|---|---|---|
| **A. 自定义三态 dialog (form/running/done)** ✅ 推荐 | `dialog.present { handle in EncryptDialogView(...) }`, 内部 `@State phase`, 后台跑 store async 方法回调切 phase | 跟老 GUI EncryptVMDialog 一致体验; running 进度日志可滚; 一个 dialog 走完全程不闪关; closeAction 按 phase 控制 | 自绘三态 + 进度 view, 代码量比标准 input 大 |
| B. 标准 `input()` 收密码 + 详情页内嵌进度区 | input dialog 拿密码 → 关 dialog → 详情页显进度 | 复用现成 input | 进度散到详情页破坏"事务在一个浮窗内闭环"心智; 多事务并发 UI 乱; 跟老 GUI 不一致 |

**选 A**: 加密事务是"一次性长流程", 必须在自己的浮窗内 form→running→done 闭环, 标准 input 表达不了 running 进度。复用 `DialogPresenter.present` 自定义 View 能力 (已为这种场景设计)。

### 选型 2: 入口位置 — 详情页"加密"section vs 顶部按钮 vs sidebar 右键

| 方案 | 优 | 劣 |
|---|---|---|
| **A. 详情页底部"加密"section** ✅ 推荐 | 跟其它 section (资源/磁盘/网络/...) 一致, 状态 (已加密/未加密 + scheme) + 动作按钮同区; 选中即见 | 多一个 section |
| B. header 操作按钮组 (跟 启动/删除 并列) | 显眼 | header 已挤 (启动/停止/解锁/锁定/删除); 加密是低频重操作, 不该跟启停并列 |
| C. sidebar 行右键菜单 | 省详情空间 | 新 GUI sidebar 暂无右键菜单基础设施; 跟"详情页编辑一切"心智不符 |

**选 A**: 新增 `DetailEncryptionSection` (跟 V1-V8 同款), 放详情页最底 (破坏性重操作沉底)。

### 选型 3: store async 方法 vs dialog 直调 Operation

| 方案 | 优 | 劣 |
|---|---|---|
| **A. NewGUIStore.encrypt/decrypt/rekey (async) + VMControl 包一层解析 qemu 路径** ✅ 推荐 | 跟 saveConfig/disk 收口一致 (单一来源); dialog 不碰 qemuImg/OVMF 路径/HVMEncryption; 失败走 `store.lastError`; 完成 store 刷缓存/refresh | 多一层 |
| B. dialog 直接调 `EncryptVMOperation.encrypt` | 少一层 | dialog 要 import HVMEncryption + QemuPaths + 自己解析 OVMF 模板, 违反"业务页不碰后端路径" (CLAUDE.md 第三方二进制约束); 缓存失效/refresh 逻辑散落 |

**选 A**: `VMControl.encryptVM/decryptVM/rekeyVM` 静态包装 (内部 `QemuPaths` 解析 qemuImg + Win OVMF 模板, 跟 `addDiskEncrypted` 同款), `NewGUIStore` async 方法在 `Task.detached` 跑 + progress 回调 + 完成刷状态。

---

## 实现要点

### VMControl 包装层 (`HVMControl/VMControl+Encryption.swift`, 新文件)

```swift
extension VMControl {
    /// 加密明文 VM (冷迁移). 内部解析 qemuImg + Win OVMF VARS 模板. requireStopped 强制.
    /// progress 回调在调用线程 (调用方负责 hop 到 main).
    static func encryptVM(bundleURL: URL, password: String,
                          progress: @escaping (String) -> Void) throws -> Bool   // 返 tpmReset

    static func decryptVM(bundleURL: URL, password: String,
                          progress: @escaping (String) -> Void) throws

    static func rekeyVM(bundleURL: URL, oldPassword: String, newPassword: String,
                        progress: @escaping (String) -> Void) throws -> Bool     // 返 tpmReset
}
```

- 内部: `assertStoppedIfNeeded(requireStopped: true)` (running 抛 `.busy`) → `QemuPaths.qemuImgBinary()` → Win guest 时 `QemuPaths.resolveRoot()/share/qemu/edk2-aarch64-vars.fd` → 调对应 `*VMOperation`
- engine/guestOS 校验由 Operation 层已做 (encrypt 拒非 QEMU/macOS), 这里不重复

### NewGUIStore async 方法 (`GUI/Store/NewGUIStore.swift`)

```swift
/// 加密事务进度行 (dialog 订阅). 每次事务开始清空.
public private(set) var encProgress: [String] = []

/// 加密明文 VM. 后台 detached 跑, progress 回 main append encProgress. 返 (ok, tpmReset).
public func encrypt(_ s: VMSummary, password: String) async -> (ok: Bool, tpmReset: Bool)
public func decrypt(_ s: VMSummary, password: String) async -> Bool
public func rekey(_ s: VMSummary, oldPassword: String, newPassword: String) async -> (ok: Bool, tpmReset: Bool)
```

- 模式 (三方法同构):
  ```
  encProgress = []
  let url = s.bundleURL
  do {
    let tpmReset = try await Task.detached(priority: .userInitiated) {
        try VMControl.encryptVM(bundleURL: url, password: pw) { line in
            Task { @MainActor in self.encProgress.append(line) }   // 回 main 喂 dialog
        }
    }.value
    clearUnlock(s.id)   // 加密后 config 变 (明→密) / 解密后转明文; 缓存全失效
    refresh()
    return (true, tpmReset)
  } catch { lastError = StoreError(...userFacing); return (false, false) }
  ```
- **加密/解密后必 `clearUnlock`**: 加密把明文 config.yaml 变 config.yaml.enc (旧解锁缓存无意义); 解密反之。改密后 subkeys 变, 同样 clear (用户重解锁)。
- 失败映射 `lastError` (走 `HVMError.userFacing`), `MainLayoutView` `.onChange` 自动弹 alert — 但 dialog 自己 form 态也要显内联错误 (跟老 GUI 一致, 不只靠全局 alert)。

### 三态 dialog (`GUI/Dialogs/NewGUIEncryptDialog.swift` 等 3 文件)

统一结构 (以 encrypt 为例):

```swift
struct NewGUIEncryptDialog: View {
    let vm: VMSummary
    let handle: HVMUI.DialogHandle
    @Environment(NewGUIStore.self) private var store

    enum Phase { case form, running, done(tpmReset: Bool) }
    @State private var phase: Phase = .form
    @State private var pw = "", pw2 = ""
    @State private var inlineError: String?

    // HVMModal 容器: title "加密 VM" / closeAction = (phase==.running ? nil : handle.close)
    //   .form:    双 SecureField + 4 字符校验 + warning "忘密不可恢复" + Win TPM 红字 + [加密] 主按钮
    //   .running: spinner + ScrollView(store.encProgress, maxHeight 140) + "请勿关闭"
    //   .done:    ✔ + (tpmReset ? TPM 重置红字 : "") + [完成] handle.close
}
```

- 提交: `phase = .running` → `Task { let r = await store.encrypt(vm, password: pw); phase = r.ok ? .done(r.tpmReset) : .form; if !r.ok { inlineError = store.lastError?.message } }`
- decrypt: 单 SecureField, 无 confirm, 无 TPM (decrypt 不重置); done 文案"已转明文, 数据不再加密保护"
- rekey: oldPassword + newPassword(confirm) + 新≠旧校验 + Win TPM 红字; running "改密中勿关 (中断两密码都解不开)"
- **必须套 `HVMModal`** (UI 控件约束); 密码框走 `HVMUI.SecureField`; 按钮走 `HVMUI.Button`

### 详情页入口 (`GUI/Layout/DetailEncryptionSection.swift`, 新)

`HVMUI.Section("加密")`, 放 `DetailOverviewView` 最底 (zIndex 最低):

- **明文 + QEMU + 非 macOS**: 状态 Badge "未加密" + 说明 + [加密 VM…] 主按钮 (停机可点) → present `NewGUIEncryptDialog`
- **加密 (`qemuPerfile`)**: 状态 Badge "已加密 · qemu-perfile" (锁图标) + [改密…] + [解密…] (都停机可点, 各 present 对应 dialog)。**不要求先解锁** (dialog 自收密码)
- **加密 (`vzSparsebundle`)**: 状态 Badge "已加密 · vz-sparsebundle" + 灰文 "VZ 加密事务 GUI 暂未接入 (走 hvm-cli)"
- **macOS guest / VZ 明文**: 整 section 显 "当前 VM 不支持整盘加密 (仅 QEMU + Linux/Windows)" 灰文 (或不渲染 — 见 D3)
- running 中 (任一事务): 该 VM 按钮 disabled (靠 dialog 占住 + store busy; 见 D4)

### 入口动作走 `store.selected` (防 stale probe 闭包)

跟 VM_DETAIL 约束一致: 按钮 action 读 `store.selected` 再 present, 不捕获渲染时 vm。

---

## 风险与待验证

| 级别 | 项 | 缓解 |
|---|---|---|
| **P0-1** | 加密/解密后缓存不一致 (旧 unlockedConfig 指向已不存在的明文/密文) | 加密/解密/改密后**必 `clearUnlock` + `refresh`**; e2e: 加密→详情页应显"已加密"+锁定态 |
| **P0-2** | running 中途关窗 / 退出 → 事务损坏 (半加密 bundle) | running 态 `closeAction = nil` (X 不显); Operation 层自身有 SignalGuard/临时目录 (DecryptVMOperation 已证); e2e 不强测中断 (危险), 靠 Operation 既有保护 |
| **P0-3** | Win TPM 重置预警缺失 → 用户丢 BitLocker recovery key | form + done 态都红字预警 (跟 CLI 一致); tpmReset 来自 Operation Result, 不猜 |
| **P0-4** | 密码错 → Operation 抛错 → dialog 卡 running | catch 回 `.form` + inlineError 显"密码错误或解密失败"; e2e: 故意输错密码 |
| P1 | 加密耗时分钟级, 用户以为卡死 | running 进度日志实时滚动 (qemu-img 有阶段输出); spinner 常转 |
| P1 | 并发: 同 VM 正加密又点启动 | Operation 抢 `.edit` lock, 启动抢 `.runtime` → 互斥抛 `.busy`; UI 侧 running 中按钮 disabled |

**P0 must-pass gate**: 用 agent 自家密码建 throwaway 明文 QEMU Linux VM → GUI 加密 (e2e: form→running→done, 详情转"已加密") → 改密 (老密码失效/新密码可解锁) → 解密 (转明文, 可正常启动配置编辑) → 全程 hvm-dbg gui 自动化。Win TPM 预警因无 throwaway Win VM **未实测**, 显式列出。

---

## PR 拆解

每 PR ≤ 2 天. 走 `GUI=new`.

| PR | 标题 | 验收 |
|---|---|---|
| **E1** | feat(control): VMControl.encryptVM/decryptVM/rekeyVM 包装 (内部解析 qemuImg + Win OVMF 模板) + NewGUIStore.encrypt/decrypt/rekey async + encProgress | `make build`; throwaway 明文 VM: store 方法单独跑 (临时入口或 hvm-dbg) 加密→解密往返 config 正确 (P0-1) |
| **E2** | feat(gui): NewGUIEncryptDialog / NewGUIDecryptDialog / NewGUIRekeyDialog 三态 (form/running/done) + DetailEncryptionSection 入口 | hvm-dbg gui: 明文 VM [加密 VM…]→双密码→进度→done→详情显"已加密"; [改密…] 老密码失效新密码解; [解密…] 转明文; 输错密码回 form (P0-1/P0-3/P0-4) |
| **E3** | docs + 回写 (CLAUDE.md 新 GUI 加密 dialog 约束 / 设计稿状态 / README 索引 / TODO) + e2e 全路径 | 加密→改密→解密 throwaway e2e 全绿; VZ/macOS 灰显 |

> **规模**: 比 VM_DETAIL 小很多 (底层全有, 只接 dialog + 入口)。3 PR。

**合入后回写**: `CLAUDE.md` (新 GUI 加密 dialog 约束: 三态 / running closeAction=nil / 加密后 clearUnlock / Win TPM 预警 / store async 收口 / 入口 gating) + 设计稿状态 → 代码已合入 + README 索引 + TODO。

---

## 未决事项 (Decisions)

| ID | 决策 | 当前默认 | 决策时机 |
|---|---|---|---|
| **D1** | dialog 形态 | 自定义三态 (选型 1-A) | 评审 |
| **D2** | 入口位置 | 详情页"加密"section 沉底 (选型 2-A) | 评审 |
| **D3** | macOS guest / VZ 明文 VM: section 灰显 vs 不渲染 | **灰显 + 文案** (告知能力边界比静默消失好) | 评审 |
| **D4** | running 中并发防护: 仅靠 Operation lock vs store 加 `busyVMs` 标记 disable 按钮 | 先靠 Operation `.edit` lock + dialog 占住 (running 时按钮在 dialog 后不可点); 若不够再加 store busy 标记 | E2 内定 |
| **D5** | 加密/解密后是否自动退选 / 跳转 | 不跳转, 留当前选中 (refresh 后详情自动反映新状态) | 本稿默认 |
| **D6** | rekey 是否要求 VM 已解锁 (复用缓存老密码) | **否** — dialog 自收老+新密码 (跟 CLI 一致, 不依赖解锁态); 更直观 | 本稿默认 |
| **D7** | 解密后 disks 仍是 qcow2 (非 raw) — 是否提示用户 | done 态文案注明"磁盘仍为 qcow2 格式" (与 CLI 一致, 不强转 raw) | 本稿默认 |

---

**评审请确认**: D1-D3 (形态/入口/边界展示) + PR 拆解 (E1-E3) + P0 gate (throwaway 明文 QEMU VM 走加密→改密→解密 e2e, Win TPM 预警未实测)。确认后从 E1 (控制层 + store) 起。
