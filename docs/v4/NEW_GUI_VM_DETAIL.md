# 新 GUI 业务页 — VM 详情完整配置编辑

> 状态: **评审中 (用户已定 D1/D2/D3)** 2026-05-30 — 用户拍板: 编辑 UX = inline section; **加密 VM 编辑本稿做** (含解锁流程); **vmnet daemon 安装本稿做**. 范围相应扩大, PR 拆解见下 V1-V9.
>
> 业务页 #2. 前置依赖: [NEW_GUI.md](NEW_GUI.md) 基础设施 + [NEW_GUI_MAIN_LAYOUT.md](NEW_GUI_MAIN_LAYOUT.md) (业务页 #1, 已合: 两栏骨架 + `NewGUIStore` + `HVMControl` 控制层 + 只读 `DetailOverviewView`). 本稿把 detail 从"只读概览 + 启停/删除"扩到"完整配置编辑".

## 目标

- **解决问题**: 业务页 #1 的 `DetailOverviewView` 只读 (overview + 启停 + 删除). 用户要改 CPU / 内存 / 磁盘 / 网络 / ISO / 共享目录 / 剪贴板等仍得回老 GUI (`GUI=old`). 本稿让新 GUI 详情页能改 VM 配置.
- **交付**:
  1. **视图无关保存层**: `HVMControl` 加 `VMControl.saveConfig(bundleURL:requireStopped:mutate:)` (明文) + 磁盘操作 `VMControl.{addDisk,resizeDisk,deleteDisk}` — 收口老 `AppModel.saveConfig` + `DiskFactory` 调用, CLI / 新 GUI 共用. 加密 VM 保存推后 (见范围外)
  2. **`NewGUIStore` 编辑能力**: `saveConfig` / 磁盘 / 共享目录 / 剪贴板 等 mutation 方法, 转发 `VMControl`, 失败走 `lastError` 冒泡
  3. **详情页编辑 section** (HVMUI 组件 + Theme token 重写, 不搬老 GUI 视觉): 资源 / 网络 / 磁盘 / ISO & 启动 / 共享目录 / 选项 等 section, running 时按约束 disabled + 提示
- **范围 (本稿)** — **明文 + 加密 VM** (加密走解锁流程):
  - **加密 VM 解锁流程** (D2 = 本稿做): 详情页加密 VM 显 [解锁] → 密码 dialog → PBKDF2 master key (routing salt/iter) → `deriveAll` subkeys → `EncryptedConfigIO.load(key: config)` 解密 → 缓存 `unlockedConfigs`/`unlockedSubKeys`/`unlockedAt` (进程内, 不落盘) → 解锁后跟明文一样可编辑; 5min auto-lock timer + 手动 [锁定]. **编辑/解密 config 走 config subkey 重密 yaml.enc; 加密盘扩容走 qcow2Disk subkey (QcowLuksFactory)**
  - **资源**: CPU 核数 / 内存 GiB (stopped 才可改)
  - **磁盘**: 主盘扩容 / 数据盘增删 (stopped; VZ raw ftruncate / QEMU qcow2 qemu-img; 加密 VM 走 QcowLuksFactory + qcow2Disk key)
  - **网络**: NIC mode / deviceModel / MAC / bridged iface / enabled (stopped)
  - **vmnet daemon** (D3 = 本稿做): 网络面板 [安装 daemon] / [重启 daemon] / [卸载] 按钮, 走视图无关化的 `VMnetSupervisor` (osascript admin Touch ID + launchd plist). bridged 模式依赖 daemon
  - **ISO & 启动**: installerISO 选择/弹出 + bootFromDiskOnly (stopped)
  - **共享目录** (QEMU only): sharedFolders 增删 + readOnly toggle (stopped, name 字符集 + 路径校验)
  - **选项**: clipboardSharingEnabled (QEMU, **可 running 热改** + IPC) / macStyleShortcuts (QEMU)
  - **Windows 装机状态机**: bootFromDiskOnly / windowsDriversInstalled 推进按钮 (装机完成 / 驱动装完)
- **范围外 (本稿不做, 后续子稿)**:
  - **加密事务** (创建加密 / decrypt 解密整 VM / rekey 改密 / 加密 clone) → [NEW_GUI_ENCRYPTION.md](NEW_GUI_ENCRYPTION.md). 本稿只做"解锁已加密 VM 以查看/编辑配置", **不**改变 VM 的加密状态
  - **OS-specific 高级 spec**: `linux.kernelCmdLineExtra` / `linux.rosettaShare` / `windows.{secureBoot,tpmEnabled,bypassInstallChecks,...}` — 低频, 推后 v1.1
  - **displaySpec** (分辨率/PPI 自定义) — 推后
  - **engine / guestOS / id 改** — 创建后不可改 (硬约束, 不提供 UI)
  - **磁盘缩容** — DiskFactory 不支持 (`.cannotShrink`), 不提供
  - **完整网络面板** (per-iface 状态 / IP 显示 / daemon 健康探测细节) → NEW_GUI_NETWORK.md; 本稿网络 section 做 NIC 字段编辑 + daemon 安装/重启/卸载三按钮即够
  - **VZ 共享目录 / VZ 剪贴板** — 共享目录仅 QEMU; VZ macOS 自带剪贴板, 不显 toggle
  - **VZ-sparsebundle 加密 VM 解锁** — 启动都未实现 (ENCRYPTION.md v2.4 QEMU 优先); 本稿加密解锁仅 `qemuPerfile` scheme

## 项目当前状态 (设计前提)

```
✅ 已有:
  app/Sources/HVMControl/  VMSummary / VMCatalog / VMControl.{start,stop,kill,status,delete}
  app/Sources/HVM/GUI/Store/NewGUIStore.swift  (vms/selectedID/lastError + 动作转发)
  app/Sources/HVM/GUI/Layout/DetailOverviewView.swift  (只读 overview + 启停/删除)
  app/Sources/HVMBundle/BundleIO.{load,save}  (明文 config.yaml 读写)
  app/Sources/HVMStorage/DiskFactory.{create,grow,delete}  (raw/qcow2 分流)
  app/Sources/HVMNet/  NetworkSpec 校验 (isValidMAC) + VMnetSupervisor (老 GUI 在 UI/)
  老 AppModel.{saveConfig,addSharedFolder,removeSharedFolder,toggleClipboardSharing}  (逻辑参考, 不复用)

❌ 缺失 (本稿补):
  VMControl.saveConfig + VMControl.{addDisk,resizeDisk,deleteDisk}  (HVMControl, 视图无关)
  NewGUIStore 编辑方法 (saveConfig draft / 磁盘 / 共享目录 / 剪贴板)
  详情页编辑 section (资源/网络/磁盘/ISO/共享/选项)
  VMnetSupervisor 的视图无关入口 (老的在 UI/, 新 GUI 要能调 — 评估迁 HVMControl 或 HVMNet)
```

**核心洞察**: 老 `AppModel.saveConfig` 把"明文/加密分流 + requireStopped 检查 + flock"耦在 GUI store 里. 新 GUI 要的是**视图无关的 `VMControl.saveConfig`** (放 HVMControl, 跟 M1 收口同理), 明文先做, 加密留 hook. 磁盘操作同样收口到 `VMControl` (加 HVMStorage 依赖), CLI 也能复用 (老 cli 若已有 disk 命令则一并改调).

## 选型对比

### 选型 1: 编辑 UX — 详情页 inline section vs 编辑 dialog

| 方案 | 形态 | 优势 | 劣势 |
|---|---|---|---|
| **A. 详情页 inline 可编辑 section** ✅ 推荐 | detail 直接铺 `HVMUI.Section` (资源/网络/磁盘/...), 字段就地可编辑, 底部"保存"按钮 (dirty 才亮) | Linear 风, 配置一屏可见可改, 不弹窗打断; 跟只读 overview 自然延续 | dirty/校验状态管理复杂; 一屏字段多 |
| B. "编辑配置" modal dialog | detail 留只读, [编辑配置] 按钮开 dialog (老 GUI `EditConfigDialog` 同款) | 编辑态隔离, dirty 简单 (dialog 关=放弃) | 弹窗打断; 跟新 GUI "detail 是主战场" 思路相悖; 大表单塞 dialog 拥挤 |
| C. 全字段即时保存 (无保存按钮) | 改一个字段立刻 saveConfig | 无 dirty 管理 | 每次 saveConfig 写全 config + validate, 误触即落盘; CPU/mem 半输入态 (空串) 会触发校验失败 |

**推荐 A** (待用户定 D1). 但**拆两类**:
- **表单字段** (CPU/内存/网络/选项/ISO/启动): inline section + 底部统一"保存"按钮 (draft 模式, 一次 saveConfig 写多字段; dirty 校验通过才亮)
- **动作操作** (加盘/扩盘/删盘/加共享/删共享/装 daemon): 即时动作 + 各自小 dialog (`dialog.input`/`dialog.confirm`), 每个自己 saveConfig — 跟老 GUI 一致, 这些本就不是"表单字段"

### 选型 2: 保存层放哪

| 方案 | 形态 | 评价 |
|---|---|---|
| **A. `VMControl.saveConfig` (HVMControl)** ✅ 选定 | 视图无关: `saveConfig(bundleURL:requireStopped:mutate:)` (明文 BundleIO.load/save + BundleLock 检查); 磁盘 `addDisk/resizeDisk/deleteDisk` (HVMStorage). 加密留 `saveConfigEncrypted(...,configKey:)` 待解锁子稿接 | 跟 M1 收口同理, CLI + GUI 共用; 明文先做不阻塞 |
| B. 新 store 内直接 BundleIO.save | NewGUIStore.saveConfig 直接调 BundleIO | 又把后端逻辑散一份 (违反 M1 收口原则 + CLAUDE.md); 加密分流没法复用 |
| C. 复用老 AppModel.saveConfig | 提取 AppModel 方法 | 用户已否决依赖老 AppModel (业务页 #1 决策) |

**选定 A**.

### 选型 3: 加密 VM 配置编辑何时做

| 方案 | 评价 |
|---|---|
| **A. 本稿只做明文, 加密留 NEW_GUI_ENCRYPTION.md** ✅ 推荐 | 加密编辑必须先解锁 (subkeys), 解锁流程是独立大件; 明文是常见场景, 先交付. 加密 VM detail 维持占位 |
| B. 本稿一起做加密 | 要先实现解锁 (decrypt config + deriveAll subkeys + 缓存 + auto-lock timer), 范围爆炸, 跟 ENCRYPTION 子稿重叠 |

**推荐 A** (待用户定 D2).

## 实现要点

### `VMControl` 扩展 (HVMControl)

```swift
public extension VMControl {
    /// 改明文 VM config (load → mutate → save). requireStopped 时 running 抛 .busy.
    /// 加密 VM (无 config.yaml) 抛明确错误, 引导走解锁子稿.
    static func saveConfig(bundleURL: URL,
                           requireStopped: Bool = true,
                           mutate: (inout VMConfig) throws -> Void) throws

    /// 加数据盘: DiskFactory.create + saveConfig 追加 DiskSpec. engine 决定 raw/qcow2.
    static func addDisk(bundleURL: URL, sizeGiB: UInt64) throws

    /// 扩盘 (主盘或指定数据盘): DiskFactory.grow + 更新 DiskSpec.sizeGiB. 只增不减.
    static func resizeDisk(bundleURL: URL, diskPath: String, toGiB: UInt64) throws

    /// 删数据盘: 移除 DiskSpec + DiskFactory.delete. 主盘不可删.
    static func deleteDisk(bundleURL: URL, diskPath: String) throws
}
```

- HVMControl 新增依赖 `HVMStorage` (DiskFactory) + `HVMNet`? (NetworkSpec 校验在 HVMBundle, 应够; vmnet daemon 安装见下)
- 磁盘加密分支 (`QcowLuksFactory` + qcow2Disk key) 本稿不接 (明文 only), 留 hook
- `clipboardSharingEnabled` 热改: `saveConfig(requireStopped: false)` + 若 running 走 `SocketClient` `IPCOp.clipboardSetEnabled` — 这条已是 IPC, 放 `VMControl.setClipboardSharing(bundleURL:enabled:)`

### vmnet daemon 安装入口

- 老 `VMnetSupervisor` 在 `app/Sources/HVM/UI/` (GUI 耦合). 新 GUI 网络 section 需"安装/重启 daemon"按钮.
- **待定 (D3)**: 把 `VMnetSupervisor` 的核心 (osascript 提权 + plist 写) 抽到视图无关层 (HVMNet 或 HVMControl), 还是新 GUI 侧薄封装. 网络面板完整化其实更适合放 [NEW_GUI_NETWORK.md](NEW_GUI_NETWORK.md) 子稿 — 本稿网络 section 可只做 NIC 字段编辑, daemon 安装按钮引导到"网络面板子稿待接入"或最小可用封装

### `NewGUIStore` 编辑方法

```swift
extension NewGUIStore {
    /// 表单保存: 一次 mutate 写多字段 (CPU/mem/network/ISO/options). 失败 lastError.
    func saveConfig(_ s: VMSummary, requireStopped: Bool = true,
                    mutate: @escaping (inout VMConfig) throws -> Void)
    func addDisk(_ s: VMSummary, sizeGiB: UInt64)
    func resizeDisk(_ s: VMSummary, diskPath: String, toGiB: UInt64)
    func deleteDisk(_ s: VMSummary, diskPath: String)
    func addSharedFolder(_ s: VMSummary, hostPath: String, name: String, readOnly: Bool)
    func removeSharedFolder(_ s: VMSummary, name: String)
    func setClipboardSharing(_ s: VMSummary, enabled: Bool)
}
```
- 全部内部 `run("...失败") { try VMControl.xxx }` (复用业务页 #1 的 lastError 冒泡) + refresh
- **draft 模式**: detail 表单区维护 `@State draft: VMConfig` (从 `selected.config` 初始化), 编辑改 draft, "保存"按钮调 `saveConfig { $0 = draft }` (或逐字段 set, 避免覆盖运行中其他改动 — 待定 D4)

### 详情页 section 结构 (明文 VM)

```
DetailOverviewView (改名 / 扩展)
├── header (name + badges)  [已有]
├── (running note)          [已有]
├── Section "概览"          [已有, 只读]
├── Section "资源"          CPU 核数 (HVMUI.Select/TextField) + 内存 GiB; stopped 才 enabled
├── Section "磁盘"          主盘行 [扩容…] + 数据盘列表 [删] + [添加数据盘…]
├── Section "网络"          每 NIC: mode(Select) / device(Select) / MAC(TextField) / bridged iface(Select, 条件) / enabled(Toggle); stopped
├── Section "ISO 与启动"    installerISO 路径 + [选择…]/[弹出] + bootFromDiskOnly(Toggle); Windows 装机推进按钮
├── Section "共享目录"      (QEMU) sharedFolders 列表 [删] + [添加…]; stopped
├── Section "选项"          (QEMU) 剪贴板共享(Toggle, 可热改) + macOS 快捷键(Toggle)
├── Section "操作"          [启动/停止/强制停止/删除]  [已有]
└── footer (表单 dirty 时) [放弃] [保存]   ← 表单字段统一保存
```

- running 时表单字段 + 磁盘/网络/共享操作全 disabled + 灰文案 "停止 VM 后可编辑"; 剪贴板 toggle 仍可改
- 加密 VM (config=nil): 维持占位, 不显编辑 section
- 单文件可能超 350 行 → 拆子 view (`DetailResourceSection` / `DetailNetworkSection` / `DetailDiskSection` / ... 各独立文件)

### probeID 命名 (R6 全覆盖)

| 控件 | probeID |
|---|---|
| CPU / 内存字段 | `detail.field.cpu` / `detail.field.memory` |
| 保存 / 放弃 | `detail.button.save` / `detail.button.discard` |
| 扩盘 / 加盘 / 删盘 | `detail.button.disk.resize-<path>` / `detail.button.disk.add` / `detail.button.disk.delete-<path>` |
| 网络字段 | `detail.network.<idx>.{mode,device,mac,bridged,enabled}` |
| ISO 选/弹 | `detail.button.iso.select` / `detail.button.iso.eject` |
| 共享增删 | `detail.button.shared.add` / `detail.button.shared.delete-<name>` |
| 剪贴板 / 快捷键 | `detail.toggle.clipboard` / `detail.toggle.macShortcuts` |

## 风险与待验证

### P0 (必须 gate)

- **P0-1: saveConfig 明文回归** — `VMControl.saveConfig` 改 CPU/mem/network → 重启 VM 验证生效; YAML 原子写不损坏 config. 用 throwaway 明文 VM e2e
- **P0-2: 磁盘操作 e2e** — 加数据盘 (qcow2/raw 按 engine) / 扩主盘 → guest 内 `lsblk` 见新尺寸 (扩容); 删数据盘 → 文件删除 + config 移除. throwaway VM 实测
- **P0-3: running 拒改闭环** — running VM 改 CPU/mem/磁盘/网络 → `VMControl.saveConfig(requireStopped:true)` 抛 .busy → store.lastError 弹 alert; 字段 disabled 提示一致. 剪贴板 running 热改 → IPC 即时生效
- **P0-4: 校验** — CPU<1 / 内存<1GiB / MAC 格式错 / bridged 未选 iface / 共享 name 非法 → 保存按钮 disabled + 字段下红字, 不落盘
- **P0-5: 加密 VM 解锁 + 编辑闭环** — qemuPerfile 加密 throwaway VM (agent 自家密码) [解锁] → 解密 config 显示 → 改 CPU → config subkey 重密 yaml.enc → 重启验证生效; 密码错报错不崩; 5min auto-lock 后需重新解锁. **VZ-sparsebundle 不接** (启动未实现)
- **P0-6: vmnet daemon 安装** — 网络 section [安装 daemon] → osascript admin Touch ID → plist 写 → bridged VM 起; [重启 daemon] bootout+bootstrap. (需用户密码, 部分手动)

### P1 (知会)

- draft 模式 vs 逐字段 set: VM 运行中其他进程改了 config (罕见) 时 draft 全覆盖会丢 — 倾向逐字段 set 或保存前 reload-merge (D4)
- 一屏 section 多, 1080×720 下滚动体验; section 折叠? (推后)
- vmnet daemon 安装入口归属 (D3) — 可能整体推到 NEW_GUI_NETWORK.md

### P2 (推后)

- 加密 VM 编辑 (等 ENCRYPTION 子稿)
- OS-specific spec / displaySpec 编辑
- 磁盘缩容 (不支持)

## PR 拆解

每 PR ≤ 2 天. 走 `GUI=new`.

| PR | 标题 | 验收 |
|---|---|---|
| **V1** | feat(control): VMControl.saveConfig (明文+加密) + addDisk/resizeDisk/deleteDisk (raw/qcow2/LUKS) + setClipboardSharing + HVMStorage/HVMEncryption 依赖 | `make build`; throwaway 明文 VM e2e: 改 CPU/加盘/扩盘/删盘全绿 (P0-1/P0-2) |
| **V2** | feat(gui): NewGUIStore 解锁流程 (unlock/lock + unlockedConfigs/SubKeys + 5min auto-lock) + detail 加密 VM [解锁] 密码 dialog → 显解密 config | hvm-dbg gui: agent 自家密码 throwaway 加密 VM 解锁 → detail 显完整 config; auto-lock; 手动锁 (P0-5) |
| **V3** | feat(gui): NewGUIStore 编辑方法 + 资源 section (CPU/内存 draft + 保存按钮 + 校验 + running disabled). 明文 + 已解锁加密 VM 都可改 | hvm-dbg gui: 改 CPU/mem 保存 → 重启验证; 加密 VM 解锁后改 → 重密 yaml.enc 验证; running disabled (P0-1/P0-3/P0-4) |
| **V4** | feat(gui): 磁盘 section (主盘扩容 + 数据盘增删; 明文 raw/qcow2 + 加密 LUKS) | hvm-dbg gui: 加盘/扩盘/删盘 → guest lsblk; 加密 VM 走 QcowLuksFactory (P0-2) |
| **V5** | feat(gui): 网络 section (NIC mode/device/MAC/bridged/enabled 编辑 + 校验) | hvm-dbg gui: 改 NIC mode/MAC → 保存 → 重启验证; 校验拦截 (P0-4) |
| **V6** | feat(net,gui): VMnetSupervisor 核心视图无关化 (osascript admin + plist) + 网络 section [安装/重启/卸载 daemon] 按钮 | 真机: 装 daemon (Touch ID) → bridged VM 起; 重启 daemon. (需用户密码, 部分手动) |
| **V7** ✅ | feat(gui): ISO & 启动 section (选/弹 ISO + bootFromDiskOnly + Windows 装机推进按钮) | ✅ hvm-dbg gui: ejectISO e2e config 翻转验证; Windows stage2 / Linux bootFromDisk 按钮可见性对照 config 实测; macOS guest 不显示. NSOpenPanel 选 ISO 无法自动化 (同 saveConfig 通路已 V3/V4 验证) |
| **V8** ✅ | feat(gui): 共享目录 section (增删 + readOnly, QEMU) + 选项 section (剪贴板热改 + 快捷键) | ✅ hvm-dbg gui: 剪贴板/macStyle/writable toggle 往返双向 e2e (修 stale probe 闭包: binding 读 live store.selected); 删除共享二次确认+取消保留. NSOpenPanel 选目录 + running IPC 热改 (P0-3) 无法自动化 (config+IPC 同老 GUI 已证通路) |
| **V9** | docs + 回写 (CLAUDE.md 新 GUI detail/解锁/daemon 约束 / v1 / TODO / 设计稿状态) + e2e 全路径走查 | 全 section + 解锁 e2e |

**合入后回写**: `docs/v1/` 现状 + `CLAUDE.md` (新 GUI detail 编辑约束: saveConfig 走 VMControl 单一来源 / running 拒 / 加密解锁分流 / 校验 / daemon 入口) + 设计稿状态 + TODO.

> **规模提示**: 用户选了全量 (加密编辑 + daemon), 9 PR. 解锁流程 (V2) + 加密盘 (V4) + daemon (V6) 是三块独立硬骨头. 按 PR 顺序推进, 每 PR 独立 e2e + commit gate.

## 未决事项 (Decisions)

| ID | 决策 | 结论 | 决策时机 |
|---|---|---|---|
| **D1** | 编辑 UX: inline section vs 编辑 dialog | **已决: inline section** (选型 1-A); 表单字段统一保存 + 动作即时 dialog | ✅ 用户 2026-05-30 |
| **D2** | 加密 VM 编辑本稿做不做 | **已决: 本稿做** (含解锁流程, 选型 3-B); 加密事务仍留 ENCRYPTION 子稿 | ✅ 用户 2026-05-30 |
| **D3** | vmnet daemon 安装入口 | **已决: 本稿做** (VMnetSupervisor 视图无关化 + 网络 section 三按钮); 完整网络面板留 NETWORK 子稿 | ✅ 用户 2026-05-30 |
| **D4** | 表单保存: draft 全覆盖 vs 逐字段 set | 建议逐字段 set (mutate 内只改编辑过字段), 防并发丢改 | V3 内定 |
| **D5** | 磁盘/saveConfig 收口 VMControl (加 HVMStorage/HVMEncryption 依赖) | **已决: 是** (跟 M1 同理) | ✅ 本稿 (选型 2-A) |
| **D6** | section 折叠 | v1 不折叠 (一屏滚动) | 本稿不决 |
| **D7** | OS-specific spec / displaySpec | 推后 v1.1 | 本稿不决 |
| **D8** | 解锁 subkeys 缓存 + auto-lock 时长 | 进程内不落盘, 5min auto-lock (跟老 AppModel 一致) | V2 内定 |

---

**用户已定 D1/D2/D3 (全量: inline + 加密编辑 + daemon)**, 设计稿据此扩到 V1-V9. 按 PR 顺序推进, V1 (控制层) 先行.
