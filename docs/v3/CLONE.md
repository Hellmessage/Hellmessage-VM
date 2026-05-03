# VM 克隆 (`HVMStorage/CloneManager`)

> 状态: **设计稿 (2026-05-04)**, 未进入实现。本稿目标是把"基于 APFS clonefile 的整 VM 全量克隆 + 身份字段重生"在 HVM 上落成方案,等评审通过再拆 PR。

## 目标

- **整 VM 克隆**: 从一个 `.hvmz` 复制出一个**独立**的新 `.hvmz`,拷贝完成后两者无任何 COW 父子链
- **APFS clonefile**: 磁盘文件复用 [`SnapshotManager.cloneFile`](../../app/Sources/HVMStorage/SnapshotManager.swift),零空间 + 瞬间完成,直到首次写入才分裂物理块
- **身份字段重生**: UUID / 显示名 / MAC / VZMacMachineIdentifier 等"机器身份"字段必须重生,避免双开冲突
- **保留装机产物**: nvram / tpm / auxiliary 装机时生成,克隆**不重置**(否则 BitLocker / Linux EFI 启动 / macOS guest 报废)
- **跨 engine 透明**: VZ raw `.img` 与 QEMU qcow2 都能 clonefile,代码不区分
- **冷克隆**: 源 VM 必须 stopped(运行中 disk 在写,clone 出来不一致)

## 与 Snapshot 的区分

| 维度 | Snapshot([SnapshotManager](../../app/Sources/HVMStorage/SnapshotManager.swift)) | Clone(本提案) |
|---|---|---|
| 输出位置 | `<bundle>/snapshots/<name>/` | 全新 `<other>.hvmz/` |
| 用途 | 时间点回滚,`restore` 覆盖回当前 bundle | 派生新 VM,可与源同时运行 |
| UUID 是否变 | 否(restore 还是同一台 VM) | **是**(独立 VM) |
| MAC 是否变 | 否 | **是**(默认重生) |
| 是否能与源同时运行 | 不适用(snapshot 不能直接"启动") | **是**(各自占 flock,各自 IP) |
| 实现复用 | — | 复用 `SnapshotManager.cloneFile`,不抽公共层(避免过度设计) |

二者**正交**,共存。本提案不动 SnapshotManager。

## 核心模型

```
源 bundle: Foo.hvmz/        →  目标 bundle: Bar.hvmz/
  config.yaml      →→→→        config.yaml  (id / displayName / createdAt 重生; networks[].mac 默认重生)
  disks/os.img     →→clonefile→ disks/os.img
  disks/data-XX.img →→clonefile→ disks/data-XX.img  (uuid8 重生,文件名跟着改)
  nvram/efi-vars.fd →→copy→→    nvram/efi-vars.fd  (保留)
  tpm/             →→copy -R→→  tpm/  (保留)
  auxiliary/aux-storage     →→copy→→ auxiliary/aux-storage  (保留)
  auxiliary/hardware-model  →→copy→→ auxiliary/hardware-model  (保留, IPSW 装机绑定的硬件模型)
  auxiliary/machine-identifier →→ 新生成 →→ auxiliary/machine-identifier  (重生)
  meta/thumbnail.png →→copy→→   meta/thumbnail.png
  snapshots/       →→ 默认不带, --include-snapshots 可选 →→
  logs/            →→ 不带 →→
  .unattend-stage/, unattend.iso →→ 不带 →→
  .lock            →→ 不带 →→
```

## 字段处理矩阵

### 必须重生

| 字段 | 来源 | 重生方式 |
|---|---|---|
| `config.id` (UUID) | VMConfig 顶层 | `UUID()` |
| `config.displayName` | VMConfig 顶层 | 用户输入(必填) |
| `config.createdAt` | VMConfig 顶层 | `Date()` |
| `config.networks[].macAddress` | NetworkSpec | `MACAddressGenerator.random()`(默认);用户可 `--keep-mac` 保留 |
| `auxiliary/machine-identifier` | VZ macOS | `VZMacMachineIdentifier()` 新建后 `.dataRepresentation` 写入,**仅 guestOS=macOS** |
| `disks/data-<uuid8>.{img,qcow2}` 文件名 | 数据盘文件命名 | `DiskFactory.newDataDiskUUID8()` 重生新 uuid8,新建文件名 + clonefile,新 uuid8 写回 `DiskSpec.path` |
| host 侧 log 子目录 | `~/Library/.../HVM/logs/<displayName>-<uuid8>/` | 新 displayName + 新 uuid8 自然得到新目录,无须显式处理 |

### 必须保留(原样复制)

| 字段/文件 | 原因 |
|---|---|
| `disks/os.{img,qcow2}` 内容 | 用户数据,clone 的核心 |
| `disks/data-*.{img,qcow2}` 内容 | 同上 |
| `auxiliary/aux-storage` (VZ macOS) | macOS guest 装机后的 NVRAM-equivalent,丢失整台 VM 报废 |
| `auxiliary/hardware-model` (VZ macOS) | IPSW 装机时绑定的硬件能力描述,与 macOS guest install 一一对应 |
| `nvram/efi-vars.fd` | EFI 变量(BootOrder / BootXXXX),装机后 OS 自己写入,重置会让 Linux/Windows 进 EFI Shell |
| `tpm/` (Win11) | swtpm 持久化的 TPM 状态(SecureBoot 信任根、BitLocker 密钥)。重置 = BitLocker 永久失效 |
| `config.{cpuCount,memoryMiB,disks[].sizeGiB,...}` 等"硬件配置" | 克隆是身份变 不是规格变 |
| `config.guestOS` / `config.engine` | 不变 — 克隆不是迁移 |
| `config.installerISO` (绝对路径) | 路径只是字符串,带过去就好;`bootFromDiskOnly=true` 时其实运行时也不读 |
| `meta/thumbnail.png` | 视觉延续(克隆后 GUI 第一帧是源的截图,等 guest 跑起来自然刷新) |

### 不带(skip)

| 路径 | 原因 |
|---|---|
| `.lock` | 是 host flock 持有者标识,克隆体首次启动会重新创建 |
| `logs/console-*.log` | 源 VM 的 guest 日志,新 VM 一身轻 |
| `.unattend-stage/`, `unattend.iso` | Win 装机产物,新 VM 若 `bootFromDiskOnly=true` 不需要;若 `=false` 启动前由 `WindowsUnattend.ensureISO` 重新生成 |
| `snapshots/` | **默认 skip**;CLI `--include-snapshots` / GUI 高级勾选可带过去 |

`.unattend-stage` 与 `unattend.iso` 在 schema 上属于"运行时产物",带不带都不影响装机后正常使用。skip 更干净。

## 前置约束

- **源 VM 必须 stopped**: 运行中 `disk` 在写,clone 出的文件可能损坏。CloneManager 启动前必须能拿到源 bundle 的 flock(独占模式)再开始 clone;克隆完成立即释放
- **源 + 目标必须同 APFS 卷**: `clonefile(2)` 跨卷会被内核拒(`EXDEV`)。GUI 让用户选目标目录时,若跨卷直接禁用并提示 "目标必须与源在同一 APFS 卷"
- **目标 bundle 路径不能存在**: 提前 `fileExists` 校验,否则抛 `diskAlreadyExists`
- **目标 displayName 唯一性**: 与 BundleIO.create 同样的"目录名 = displayName.hvmz"约定;若同名已存在,GUI 自动追加 ` (副本)` / ` (副本 2)` 后缀,CLI 直接抛错让用户改名
- **engine / guestOS 不可改**: 克隆**不是**迁移工具。要换 engine 走"导出磁盘 + 新建 VM 导入"
- **加密 VM 克隆**: 走加密路线后(参见 [ENCRYPTION.md](ENCRYPTION.md)),克隆是"复制 sparsebundle + chpass + 内部走本流程"。**本稿不实现加密 VM 克隆**,加密合入后再补一层 wrapper

## 模块设计

### 新增 `HVMStorage/CloneManager.swift`

```swift
public enum CloneManager {
    public struct Options: Sendable {
        public var newDisplayName: String       // 必填,写入 config.displayName 与目录名
        public var targetParentDir: URL?        // nil 则与源同目录
        public var keepMACAddresses: Bool       // 默认 false,即重生
        public var includeSnapshots: Bool       // 默认 false
    }

    public struct Result: Sendable {
        public let sourceBundle: URL
        public let targetBundle: URL
        public let newID: UUID
        public let newDataDiskUUID8s: [String: String]   // old uuid8 → new uuid8
    }

    /// 整 VM 克隆. 源必须 stopped (调用方先获取源 flock 再调本函数).
    public static func clone(sourceBundle: URL, options: Options) throws -> Result
}
```

### 实现步骤

```
1. 校验 options.newDisplayName (1-64 char, 同 SnapshotManager.validateName 规则; 不允许 / .. 控制字符)
2. 解析目标 bundle URL = (targetParentDir ?? sourceBundle.deletingLastPathComponent())
                          / "<newDisplayName>.hvmz"
3. fileExists 校验目标不存在; 抛错或追加后缀 (CLI 直接抛, GUI 已经在上层做后缀逻辑)
4. 同卷校验:
   - statfs(sourceBundle) 与 statfs(targetParent) 比较 f_fsid
   - 不同 → 抛 HVMError.storage(.crossVolumeNotAllowed) (新增 case)
5. 加载源 config = BundleIO.load(sourceBundle)  (拿到 schema 与 disks/networks)
6. mkdir 目标 bundle 与 disks/auxiliary/nvram/tpm/meta 子目录
7. clone 主盘:
   - SnapshotManager.cloneFile(src: <src>/disks/<main>, dst: <dst>/disks/<main>)
     (主盘文件名不变, 因为它是 os.img / os.qcow2 不带 uuid)
8. clone 数据盘 (重生 uuid8):
   for each disk in config.disks where role == .data:
       newUUID8 = DiskFactory.newDataDiskUUID8()
       newName  = BundleLayout.dataDiskFileName(uuid8: newUUID8, engine: config.engine)
       SnapshotManager.cloneFile(src: <src>/disk.path, dst: <dst>/disks/<newName>)
       // 同时把 config.disks[i].path 改成 "disks/<newName>"
       record (oldUUID8, newUUID8) into Result.newDataDiskUUID8s
9. copy auxiliary/ 整个 (FileManager.copyItem 不走 clonefile, 但都是 KB 级小文件):
   - aux-storage / hardware-model 原样
   - 若 guestOS == .macOS:
       生成新 VZMacMachineIdentifier()
       写 dataRepresentation 到 <dst>/auxiliary/machine-identifier
       (覆盖刚 copy 过来的)
10. copy nvram/ 整个 (efi-vars.fd 也是 KB 级)
11. copy tpm/ 整个 (Win11 swtpm state, 同样 KB 级)
12. copy meta/thumbnail.png (若存在)
13. 若 options.includeSnapshots: copy snapshots/ 整个 (内部递归 copyItem; 不重 clone, 因 snapshot 内部已是 clonefile, copyItem 也走 APFS COW)
14. 重生 config 顶层身份字段:
    config.id          = UUID()
    config.displayName = options.newDisplayName
    config.createdAt   = Date()
    if !options.keepMACAddresses:
        for i in config.networks.indices:
            config.networks[i].macAddress = MACAddressGenerator.random()
15. 写目标 config.yaml (BundleIO.save / 走 yaml 序列化)
16. 不创建 .lock — 目标 VM 首次启动时自然创建
17. 返回 Result
```

### 错误回滚

任意一步失败 → `try? FileManager.default.removeItem(at: targetBundle)` 整目录清掉。clonefile 已分配的 inode 会随之释放。**CloneManager 不留半成品**。

### 同步 vs 异步

主盘 clone 几毫秒,但若用户带 `--include-snapshots` 且源 snapshot 多达几十个,copyItem 走 APFS COW 也可能秒级。CloneManager 暴露**同步**接口;GUI 上层 `Task.detached` 包一层走后台 + 进度条(进度按 phase 推进:校验 / 主盘 / 数据盘 / aux / nvram / tpm / snapshots / config)。

## CLI 接口

```
hvm-cli clone <source-name-or-path>  --name <new-display-name>
                                     [--target-dir <dir>]
                                     [--keep-mac]
                                     [--include-snapshots]
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `<source>` | 是 | VM 显示名 / bundle 路径,与 `hvm-cli start` 同款解析 |
| `--name` | 是 | 新 VM 显示名,1-64 字符,字母/数字/中文/`-`/`_`/`.`/空格 |
| `--target-dir` | 否 | 目标父目录;缺省 = 源父目录(通常是 `~/Library/.../VMs/`) |
| `--keep-mac` | 否 | 保留所有 NIC MAC(用户自己负责不在同 LAN 双开) |
| `--include-snapshots` | 否 | 把源的 `snapshots/` 一并复制 |

退出码:
- 0 成功
- 64 参数错误(同名已存在 / 跨卷 / 源 running)
- 65 IO 失败(磁盘满 / 权限 / clonefile 内核拒)

## GUI 接口

- VM 列表行右键菜单 / 详情页"操作"区:加 **"克隆..."** 按钮
- 点击后弹 `HVMModal`:
  - "新虚拟机名称" 文本框(`HVMTextField`,默认填 `<源名> 副本`)
  - "目标位置" 路径选择(默认与源同目录,跨卷时 picker 自动 filter)
  - 折叠 "高级":
    - `HVMToggle` "保留 MAC 地址"(默认关)
    - `HVMToggle` "包含快照"(默认关)
  - 底部按钮:`PrimaryButtonStyle "克隆"` + `GhostButtonStyle "取消"`
  - **不允许**遮罩点击关闭(沿用约束)
- 进行中:Modal 切到进度条态(`HVMModal closeAction = nil` 隐藏 X — 不可中断,clonefile 不可优雅取消)
- 完成:Modal 切到成功态,提供 "立即启动新 VM" / "在列表中查看" / "完成" 三个按钮
- 失败:走 `ErrorDialog` 标准错误对话框,不用 NSAlert

源 VM 状态判断:若 GUI 检测到源 running,克隆按钮置灰 + tooltip "请先停机再克隆"。

## 与 hvm-dbg 的关系

`hvm-dbg` 是诊断工具,**不**加 clone 子命令。克隆是用户操作,走 hvm-cli / GUI。

## 异常处理

| 失败点 | 处理 |
|---|---|
| 源 VM running(flock 拿不到独占) | 抛错 `HVMError.bundle(.lockHeldElsewhere)`,提示用户先停机 |
| 跨卷 | 抛错 `HVMError.storage(.crossVolumeNotAllowed)`,提示同卷再试 |
| 目标已存在 | CLI 直接抛 `HVMError.storage(.diskAlreadyExists)`;GUI 上层在弹框前已自动追加 `副本 2` 等后缀 |
| clonefile 失败(磁盘满) | 抛 `HVMError.storage(.ioError(errno: ENOSPC))`,清理 targetBundle |
| copy auxiliary / nvram / tpm 失败 | 同上,清理 targetBundle |
| 写新 config.yaml 失败 | 同上,清理 targetBundle(此时磁盘已 clonefile,但 config 缺失,目录无意义) |
| 源 config 加载失败(schema 升级失败) | 抛错并不创建目标 — 用户先把源 VM 升级到当前 schema |

**CloneManager 始终保证:成功 = 完整可用的新 bundle;失败 = 没有 partial 残留**。

## 测试覆盖(单测)

`app/Tests/HVMStorageTests/CloneManagerTests.swift` 新增,目标:

| 测试 | 期望 |
|---|---|
| `clone_basic_linux_vz` | Linux/VZ 源,clone 后:目标存在,config.id 不同,主盘 clonefile 成功(`stat -f %i` inode 不同但内容一致 via SHA256) |
| `clone_macOS_regenerates_machineIdentifier` | macOS guest:目标 `auxiliary/machine-identifier` 字节 ≠ 源 |
| `clone_macOS_keeps_hardwareModel` | macOS guest:目标 `auxiliary/hardware-model` 与源**完全相同** |
| `clone_data_disks_get_new_uuid8` | 源含 2 块数据盘,clone 后目标数据盘文件名 uuid8 与源不同,`config.disks[].path` 跟着更新 |
| `clone_keeps_mac_when_flag_set` | `keepMACAddresses=true` 时 MAC 与源相同 |
| `clone_regenerates_mac_default` | 默认 MAC 不同,且通过 `MACAddressGenerator.validate` |
| `clone_skips_snapshots_by_default` | 源 `snapshots/foo`,目标无 `snapshots/` |
| `clone_includes_snapshots_when_flag_set` | `includeSnapshots=true`,目标 `snapshots/foo` 存在 + meta.json 相同 |
| `clone_target_exists_throws` | 目标已存在 → 抛错,源不动 |
| `clone_running_source_throws` | 源 flock 持有 → 抛错,目标不创建 |
| `clone_cleans_partial_on_failure` | 用 mock 让 step 11 (tpm copy) 失败 → targetBundle 不存在(已 cleanup) |
| `clone_yaml_schema_preserved` | 目标 config.yaml 重新加载 schemaVersion 与源一致 |

QEMU qcow2 路径与 raw 路径走的是同一份代码(都是 cloneFile),用一个 fixture 验证即可,**不**为 qcow2 重复一遍全套用例。

## 不做什么

1. **不做 linked clone**: VZ raw 不支持 backing,qcow2 backing 跨 bundle 维护成本高;APFS clonefile 已经接近 linked 的空间效率
2. **不做 cross-engine 克隆**: 不是迁移工具,不在范围
3. **不做 cross-host 克隆**: 跨机器复制 = 用户自己 `cp -R` bundle(同卷限制变成"用户自负")。本稿不引入这条通路
4. **不做 in-place clone(就地原地分裂)**: 没有合理用例
5. **不重生 NVRAM / EFI 变量**: 重生 = Linux/Windows 启动失败
6. **不重生 TPM state**: 重生 = BitLocker 永久失效;源 + 克隆都 BitLocker 启用时,克隆开机后用户感知是同一台机器(TPM identity 重叠)。**这是已知 trade-off**,GUI 在勾选 "包含 TPM 数据" 时不允许取消(默认就是带,用户无选择)。重置 TPM 与重新装 Windows 等价
7. **不重生 macOS hardware-model**: 它由 IPSW 决定,VZMacAuxiliaryStorage 装机时一锤定音;重生 = macOS guest 拒绝启动
8. **不重生 disks/os.\* 文件名**: 主盘命名按 `BundleLayout.mainDiskFileName(for: engine)` 是 engine 决定的固定值,不带 uuid;数据盘是 `data-<uuid8>.\*`,uuid8 重生
9. **不在线克隆**: 源必须 stopped。GUI 不弹 "停机后克隆?" 自动停机选项 — 用户自己掌控
10. **不做 schema 升级**: 源 schema 必须等于当前(v2)。低 schema 必须先用 ConfigMigrator 升级再克隆
11. **不复制 host 侧 log**: `~/Library/.../HVM/logs/<displayName>-<uuid8>/` 是 per-VM uuid8,克隆后新 uuid8 自然得到新目录,旧 log 留给源
12. **不删源**: clone 是 copy 不是 move

## 风险与待验证项

| 编号 | 项目 | 优先级 | 验证方法 |
|---|---|---|---|
| C1 | macOS guest 克隆后能否启动(machine-identifier 重生 + hardware-model 不变) | **P0** | 真机 IPSW 装一台 macOS guest,clone 一份,两台先后启动各自 boot 到 Setup |
| C2 | macOS guest 双开(源 + 克隆同时运行) | P1 | C1 通过后两台同时启动,看 VZ 是否拒绝(若拒绝则文档明示不支持双开) |
| C3 | Win11 克隆后 BitLocker 是否仍工作 | **P0** | 装一台开 BitLocker 的 Win11,clone 一份,克隆体启动看是否仍能解锁系统盘 |
| C4 | Linux 克隆后 EFI BootOrder 是否仍工作 | P1 | 装 Ubuntu/Fedora,clone 一份,克隆体直接 boot 到系统(不进 EFI Shell) |
| C5 | 跨卷拒绝(`EXDEV`)的检测路径 | P1 | 准备一个外接 APFS 卷,跨卷克隆,确认抛 `crossVolumeNotAllowed` 而非 partial |
| C6 | 大主盘(64 GiB+)实际 clonefile 时延 | P2 | benchmark,目标 < 100 ms |
| C7 | snapshots/ 复制(`--include-snapshots`)的 COW 保留 | P2 | 源 snapshot 占 100 MB(已 clone),clone 后目标 snapshot 物理占用应 < 10 MB(APFS copyItem 也走 COW) |
| C8 | 同名 VM 自动追加 "副本 N" 在 GUI 是否触发文件系统 race | P2 | 多次连续点克隆,看 N 是否单调递增不冲突 |

C1 / C3 是 **must pass** 才合入;其他在 PR 拆解阶段验证。

## 落地拆解 (PR 切分)

| PR | 内容 | 时间盒 |
|---|---|---|
| **PR-1** | `HVMStorage/CloneManager.swift` 模块 + 单测(覆盖 12 个 case)+ `HVMError.storage.crossVolumeNotAllowed` case | 1 天 |
| **PR-2** | `hvm-cli clone` 子命令 + e2e(用 fixture VM 真跑一遍 clone + 启动新 VM 看 console boot) | 0.5 天 |
| **PR-3** | GUI:列表右键菜单 + clone modal + 进度条态 + 完成态(三按钮) | 1 天 |
| **PR-4** | C1 / C3 真机验证;若失败,补 patch + 文档边界更新 | 0.5 天 |
| **PR-5** | 文档同步:把 [STORAGE.md](../v1/STORAGE.md) "Snapshot" 节后面追加 "Clone" 节;[VM_BUNDLE.md](../v1/VM_BUNDLE.md) 字段表加注 "克隆时是否重生";`CLAUDE.md` 加 "克隆约束" 节(必须 stopped / 同卷 / 不双开 macOS guest 等) | 0.3 天 |

合计 ~3.3 天 / 1 人。PR-1 / PR-2 可并行起草,PR-3 接 PR-1 之后(依赖 CloneManager 接口稳定)。

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| D1 | macOS guest 克隆是否标"实验性"? | **是**,GUI 创建按钮旁加 ⚠️ "macOS 克隆为实验性,Apple 服务行为未知" | 待决,看 C1 / C2 真机结果 |
| D2 | Win11 克隆是否提示 "可能需重新激活"? | 是,GUI 进度条完成态展示一次性提示 | 已决 |
| D3 | `--include-snapshots` 默认值 | false | 已决 |
| D4 | `--keep-mac` 默认值 | false(重生) | 已决 |
| D5 | 同源多次连续克隆的命名策略 | GUI 自动追加 "副本" / "副本 2" / "副本 3";CLI 不自动,用户必须 `--name` | 已决 |
| D6 | 加密 VM 克隆 | 本稿不实现;[ENCRYPTION.md](ENCRYPTION.md) 合入后,加一层"复制 sparsebundle → attach → clone 内部 → detach → chpass" wrapper | 已决,排到 ENCRYPTION 之后 |
| D7 | 克隆后是否自动启动新 VM | 不自动,GUI 完成态提供"立即启动"按钮让用户手动触发 | 已决 |
| D8 | 是否提供 "克隆配置但不复制磁盘"(只 config + 空盘)? | **不做**,这就是"新建相同规格 VM",走 GUI 创建向导即可,克隆不分流这种语义 | 已决 |

## 相关文档

- [ENCRYPTION.md](ENCRYPTION.md) — 加密 VM 克隆 wrapper 由本稿合入后再补
- [STORAGE.md](../v1/STORAGE.md) — Snapshot 实现(本稿复用 `cloneFile` helper)+ 磁盘文件命名规则
- [VM_BUNDLE.md](../v1/VM_BUNDLE.md) — bundle 布局 + config schema(本稿不改 schema)
- [VZ_BACKEND.md](../v1/VZ_BACKEND.md) — VZMacMachineIdentifier / VZMacHardwareModel 语义
- [QEMU_INTEGRATION.md](../v1/QEMU_INTEGRATION.md) — qcow2 与 swtpm state 文件存放
- [../../CLAUDE.md](../../CLAUDE.md) — 全局约束(本稿合入后需新增"克隆约束"节)

---

**最后更新**: 2026-05-04
**状态**: 设计稿,等评审 + C1 / C3 真机验证后启动 PR-1
