# VM Bundle 格式 (`.hvmz`)

## 目标

一个 `.hvmz` 目录自包含一台 VM 的**全部持久化状态**, 可整个拷贝迁移。设计要点:

1. 目录而非单文件, 方便编辑 / diff / 增量备份
2. 与 hell-vm 的 `.hellvm` 严格隔离, 扩展名不同, 内部结构也不同
3. 同一时刻仅允许一个进程打开(fcntl flock 互斥), 避免两处并发改 config 或写磁盘
4. ISO 只存绝对路径, 不复制进 bundle(避免重复占用几 GB)
5. config 带 `schemaVersion`, 跨版本走 `ConfigMigrator` 链式升级

## 目录布局

```
foo.hvmz/
├── config.yaml              — VMConfig 的 YAML 序列化(权威配置, schema v2)
├── auxiliary/               — VZ macOS guest 必需数据
│   ├── aux-storage          — VZMacAuxiliaryStorage 后端文件
│   ├── machine-identifier   — VZMacMachineIdentifier (Data)
│   └── hardware-model       — VZMacHardwareModel (Data, 一次性生成不可变)
├── disks/                   — 所有磁盘镜像
│   ├── os.img               — VZ 后端主盘 (raw sparse)
│   ├── os.qcow2             — QEMU 后端主盘 (qcow2)
│   └── data-<uuid8>.{img|qcow2}  — 可选数据盘, 同 engine 的格式跟随
├── nvram/                   — Linux/Windows guest EFI 变量
│   └── efi-vars.fd          — VZEFIVariableStore / QEMU OVMF VARS
├── tpm/                     — Win11 swtpm 持久化 (NVRAM 表征)
├── snapshots/               — 快照子目录
├── logs/                    — guest 内部产生的日志(唯一允许的写入来源是
│                              ConsoleBridge / QemuConsoleBridge)
│   └── console-<date>.log
├── unattend.iso             — Win 装机 AutoUnattend.xml 打的 ISO (运行时生成)
├── .unattend-stage/         — unattend ISO 的 staging
├── .lock                    — flock 占用文件 + 持有者 JSON
├── meta/                    — 非关键元数据
│   └── thumbnail.png        — GUI 列表缩略图
└── (无 run/ 子目录, 运行时 socket 走全局 HVMPaths.runDir/<uuid>.*)
```

注:

- `auxiliary/` 仅 `guestOS=.macOS` 用, 丢失整台 VM 报废
- `nvram/` Linux/Windows 用; Windows 还配 `tpm/`
- `unattend.iso` 与 `.unattend-stage/` 仅 Windows guest 装机阶段
- 运行时 socket(IPC / QMP / HDP / vdagent / swtpm)走 `~/Library/Application Support/HVM/run/<uuid>.*`, **不在 bundle 内**
- VM 删除时**不**清理 host 侧 `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/`

## `config.yaml` Schema (v2)

> v1 (.json) 已断兼容: `BundleIO.load` 检测到 `config.json` 存在但无 `config.yaml` 时直接报错,要求重新创建或手动迁移。

### 顶层字段

| 字段 | 类型 | 说明 | 克隆 |
|---|---|---|---|
| `schemaVersion` | Int | 当前 `2`。> 当前抛 `.invalidSchema`; < 当前走 `ConfigMigrator` | 保留 |
| `id` | UUID | bundle 创建时生成, 跟随一生 | **重生** |
| `createdAt` | ISO8601 Date | 创建时间, 仅展示 | **重生** |
| `displayName` | String | 展示名, 允许中文, 可与目录名不一致 | **重生** (用户输入) |
| `guestOS` | `macOS` \| `linux` \| `windows` | 其他值拒绝 | 保留 |
| `engine` | `vz` \| `qemu` | 缺省 `.vz`(老 v1 兼容兜底), `validate()` 校验合法组合 | 保留 |
| `cpuCount` | Int | VZ 后端范围由 VZ API 限定 | 保留 |
| `memoryMiB` | UInt64 | MiB | 保留 |
| `disks` | [DiskSpec] | 至少一项, 第一项 `role=main` | 内容 cloneFile; 数据盘 `data-<uuid8>.*` 文件名重生 + `path` 同步 |
| `networks` | [NetworkSpec] | 可空 | `macAddress` 默认重生 (`--keep-mac` 保留) |
| `installerISO` | String? | 绝对路径, **不复制进 bundle** | 保留 (绝对路径, 跨 VM 共用 ISO) |
| `bootFromDiskOnly` | Bool | 装机完成后置 true | 保留 |
| `windowsDriversInstalled` | Bool | Windows 三态切换(false=ramfb / true=hvm-gpu-ramfb-pci) | 保留 |
| `clipboardSharingEnabled` | Bool | 默认 true; 仅 QEMU 走 vdagent, VZ macOS guest 自带忽略此字段 | 保留 |
| `macStyleShortcuts` | Bool | 默认 true; 仅 QEMU 生效, host cmd→guest ctrl | 保留 |
| `macOS` | MacOSSpec? | 仅 `guestOS=macOS` | 保留 |
| `linux` | LinuxSpec? | 仅 `guestOS=linux` | 保留 |
| `windows` | WindowsSpec? | 仅 `guestOS=windows` | 保留 |

> 克隆细节见 [STORAGE.md "Clone: 整 VM 克隆"](STORAGE.md). `auxiliary/machine-identifier` (macOS) 重生; `auxiliary/hardware-model` / `aux-storage` / `nvram/efi-vars.fd` / `tpm/*` 全保留.

`VMConfig.validate()` 强制:

| guestOS | 允许的 engine |
|---|---|
| `macOS` | 只能 `vz` (VZMacOSInstaller 路径) |
| `linux` | `vz` 或 `qemu` |
| `windows` | 只能 `qemu` (VZ 无 TPM) |

### DiskSpec

```yaml
disks:
  - role: main          # main 必须有且只有一个; 其余 data
    path: disks/os.qcow2  # 相对 bundle root
    sizeGiB: 64
    format: qcow2       # raw / qcow2
    readOnly: false
```

- `format` 跟 `engine` 走: VZ → `raw`, QEMU → `qcow2`(VZ 强约束 raw, qcow2 拒绝)
- 运行时**严格读 `DiskSpec.format`**, 禁止靠 `path` 扩展名推断
- `format` 缺字段时按 `path` 扩展名兜底(`.qcow2` → qcow2, 其他 → raw), 仅给手工编辑的老 yaml 容错
- `path` 必须落在 `disks/` 下, 不能跳出 sandbox(`BundleLayout.isDiskPathInSandbox`)
- 老 QEMU VM 是 raw `.img`(从老版本带过来) 仍可继续运行, 不强制迁移

### NetworkSpec

```yaml
networks:
  - mode: vmnetBridged    # user / vmnetShared / vmnetHost / vmnetBridged / none
    macAddress: "52:54:00:a1:b2:c3"
    socketVmnetPath: null  # 留空走 SocketPaths 标准路径
    bridgedInterface: en0  # 仅 vmnetBridged
    deviceModel: virtio    # virtio / e1000e / rtl8139
    enabled: true
```

- 老枚举名兼容: `nat→user / shared→vmnetShared / bridged→vmnetBridged`(由 `NetworkSpec.init(from:)` 拦下)
- vmnet* 模式靠 `socket_vmnet`(brew 装), 协议固定路径见 [NETWORK.md](NETWORK.md)
- `enabled=false` 时启动不挂, 运行中可 QMP 热插拔

### MacOSSpec

```yaml
macOS:
  ipsw: /path/to/UniversalMac_*.ipsw
  autoInstalled: true
```

### LinuxSpec

```yaml
linux:
  kernelCmdLineExtra: null
  rosettaShare: false       # 当前未接 ConfigBuilder, 见 docs/v2/05-pending-from-v1.md L-2
```

### WindowsSpec

```yaml
windows:
  secureBoot: true
  tpmEnabled: true
  bypassInstallChecks: true       # WindowsUnattend 注入 LabConfig\Bypass*Check
  autoInstallVirtioWin: false     # 当前 false: UTM Guest Tools ISO 已替代
  autoInstallSpiceTools: true     # 装完静默装 spice-guest-tools.exe
```

## 命名规则

- **Bundle 目录**: 任意名 + `.hvmz` 扩展名。GUI 默认用 `displayName` 小写 + `-` 替换空格
- **主盘**: `disks/os.img` (VZ) 或 `disks/os.qcow2` (QEMU), 由 `BundleLayout.mainDiskFileName(for:)` 在创建时生成, 写入 `DiskSpec.path` 持久化
- **数据盘**: `disks/data-<uuid8>.{img|qcow2}`, 同 engine 跟随
- **ISO**: 不进 bundle, 只记 `installerISO` 绝对路径
- **缩略图**: `meta/thumbnail.png`(`ThumbnailWriter` atomic 写, VZ + QEMU 共用)

> **运行时禁止从常量推断主盘路径**: `VMConfig.mainDiskRelPath` / `VMConfig.mainDiskURL(in:)` 是唯一入口。`BundleLayout.mainDiskFileName(for:)` 仅创建时调一次, 其余位置不得调用。老 API `mainDiskName` / `mainDiskURL(_ bundle)` 已删。

## BundleLayout 公开 API

仅保留**与 VM 无关的结构常量** + **创建时一次性文件名生成器**:

```swift
// 文件 / 目录名
configFileName / legacyConfigFileName / lockFileName
disksDirName / auxiliaryDirName / nvramDirName / logsDirName / metaDirName / snapshotsDirName
nvramFileName / auxStorageName / machineIdentifier / hardwareModel / thumbnailName

// 路径助手
configURL(_:) / legacyConfigURL(_:) / lockURL(_:)
disksDir(_:) / auxiliaryDir(_:) / nvramDir(_:) / nvramURL(_:)
logsDir(_:) / metaDir(_:) / snapshotsDir(_:) / snapshotDir(_:name:)
serialSocketURL(_:) / tpmStateDir(_:) / unattendISOURL(_:) / unattendStageDir(_:)

// 创建时一次性生成器 (运行时不调)
mainDiskFileName(for engine: Engine) -> String
dataDiskFileName(uuid8:engine:) -> String

// sandbox 校验
isDiskPathInSandbox(_:) -> Bool
```

## 互斥锁 (flock)

### 为什么必须锁

- VZ 不允许两个 `VZVirtualMachine` 同时使用同一份磁盘文件
- QEMU 同样不允许多进程写 qcow2
- config.yaml 并发修改会竞争, macOS auxiliary 数据并发写更危险

### 实现 (`BundleLock`)

```swift
public final class BundleLock {
    public enum Mode: String { case runtime, edit }
    public init(bundleURL: URL, mode: Mode, socketPath: String = "") throws
    // 1. open(bundle/.lock, O_RDWR | O_CREAT, 0644)
    // 2. flock(fd, LOCK_EX | LOCK_NB)
    //    EWOULDBLOCK → throw .busy(pid:, holderMode:)
    // 3. ftruncate + 写入 HolderInfo JSON (pid/host/socketPath/mode/since)
    public func release()
    deinit { release() }

    public static func isBusy(bundleURL: URL) -> Bool        // 无副作用探测, hvm-cli list 用
    public static func inspect(bundleURL: URL) -> HolderInfo?
}
```

### 进程崩溃后的锁

- flock 内核持有, 进程退出自动释放, 不留死锁
- `.lock` 文件里的 PID 可能过期, 新进程抢锁时覆盖即可
- GUI 列表刷新时, `isBusy=false` 但 `.lock` 存在 = stopped(.lock 文件本身不删)

### 跨主机限制

- flock(2) 只在本机 inode 上互斥
- bundle 落 NFS/SMB/exFAT 卷上, 两台主机可同时拿到锁 → 破坏 disks/auxiliary
- `BundleLock` init 时 `statfs` 探测, 非本地 (apfs/hfs) 卷给一次 warn(进程级 dedup), 不强禁

### 与 hell-vm 互不干扰

- 扩展名不同: `.hvmz` vs `.hellvm`
- 锁文件名 `.lock` 与 hell-vm 内部命名无关
- 两套同时跑不同 bundle 完全安全

## schema 演化策略

### 设计原则

- 新字段**只加不改**, 加字段必须带默认值; Codable `init(from:)` 用 `decodeIfPresent` 兜底
- 删字段**保留 yaml key**, 读取时忽略
- 不兼容变更(改字段语义/重命名/单位变化)必须升 `schemaVersion` + 加迁移 hook
- 链式升级 `v_n → v_n+1 → ... → current`, 不允许跨版本跳

### 当前实现

- `VMConfig.currentSchemaVersion = 2`
- `ConfigMigrator.migrate(data:from:to:)` 框架已就位, 但**当前无 v2→v3 hook**(下一版加时按模板)
- v1 (.json) **已断兼容**: `BundleIO.load` 检测到 `legacyConfigFileName` 存在但无 `configFileName` 时, 抛 `BundleError` 报"重新创建 VM 或手动迁移", **不进入 migrator**

### `BundleIO.load` 流程

1. 没有 `config.yaml` 但有 `config.json` → 报错(老 schema 已断兼容)
2. 用 `_SchemaEnvelope` 只解 `schemaVersion` 字段
3. `> currentSchemaVersion` → 抛 `.invalidSchema`(让用户升 HVM)
4. `< currentSchemaVersion` → 走 `ConfigMigrator.migrate` 升到当前
5. `== currentSchemaVersion` → 直接 `Yams.YAMLDecoder().decode(VMConfig.self, ...)`
6. 升级后 `BundleIO.save` 以 `currentSchemaVersion` 重写 yaml, 下次 load 不再走 migrator

### 加新版本步骤(模板)

```swift
// 1. VMConfig.currentSchemaVersion +1
// 2. ConfigMigrator.migrate 的 switch 加 case
//    case (2, 3): current = try migrate_v2_to_v3(current)
// 3. 实现 migrate_v2_to_v3(_:Data) -> Data:
//    Yams.load → [String: Any] dict 改 → Yams.dump → Data
//    最后写入 dict["schemaVersion"] = 3
```

## I/O 原子性

`config.yaml` 写入走 "tmp + atomic rename":

```swift
let tmp = bundleURL.appendingPathComponent("config.yaml.tmp")
try data.write(to: tmp, options: .atomic)
try FileManager.default.replaceItem(at: configURL, withItemAt: tmp, ...)
```

避免半写入的 yaml 导致下次加载崩溃。

## 验证

加载 bundle 时必做校验:

1. `config.yaml` 存在且可被 Yams 解析为 `VMConfig`
2. `schemaVersion <= currentSchemaVersion`
3. `guestOS` / `engine` 合法枚举值, `validate()` 通过
4. 主盘文件存在
5. macOS guest 必须有 `auxiliary/hardware-model` + `machine-identifier`, 否则识别为"未完成创建"
6. 所有 `DiskSpec.path` 通过 `BundleLayout.isDiskPathInSandbox`(disks/ 下且无 `..`)

失败抛 `HVMError.bundle(.invalid(reason:))`, GUI 用 `ErrorDialog` 展示。

## 删除 bundle

- GUI 删除 = 移入废纸篓(`NSWorkspace.recycle`)
- CLI `hvm-cli delete <bundle>`: 默认废纸篓; `--purge` + `--force` 才直接 `rm -rf`
- 删除前必须确认 `.lock` 未被持有
- host 侧 `~/Library/Application Support/HVM/logs/<displayName>-<uuid8>/` **不**自动清理

## 不做什么

1. **不加密 bundle**(FileVault 已负责)
2. **不签名 bundle**(用户改 yaml 自负)
3. **不嵌入 snapshot 进 config**(独立 `snapshots/` 子目录, qcow2 内部链 + VZ save-state)
4. **不做 iCloud Drive 同步指引**(同步工具与 flock / sparse 文件冲突, 明确不支持)
5. **不再支持 v1 .json**(2026 年初已断兼容)

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| B1 | 是否支持"模板 bundle" | 不做, 用 clonefile 手动克隆 | 已决 |
| B3 | 是否引入 `config.lock` edit 模式 | 字段保留, 暂不强制使用 | M2 |

---

**最后更新**: 2026-05-04
